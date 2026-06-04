# 갭 02 — Outbox Publisher Worker

> **버전**: v0.2 → 0.3 진입 시 우선 구현
> **위치**: `@erp-harness/core` 또는 `business/_shared/outbox/`
> **영향**: 모든 모듈의 이벤트 발행
> **의존**: `event_outbox` 테이블 (스키마는 v0.9.0 에 존재) + 갭 01 (idempotency)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- `event_outbox` 테이블 존재
- 비즈니스 트랜잭션 안에서 outbox row INSERT 패턴 명시 (`integration.md` § 1.1)
- **outbox 폴링 + 발행 worker 부재** — outbox row 가 쌓이기만 하고 실제 이벤트 버스로 발행되지 않음

### 영향

- `DELIVERY_DISPATCHED` 이벤트가 inventory OUT movement 트리거 못함 (logistics → inventory 흐름 단절)
- `DELIVERY_COMPLETED` 가 payroll work_log 트리거 못함
- `period_closed` 가 reports immutable 마킹 안 됨
- 모든 cross-module 이벤트 흐름 작동 X

### 목표

outbox 폴링 + at-least-once 발행 + 실패 재시도 + DLQ 처리하는 worker.

---

## 1. 인터페이스

```typescript
// business/_shared/outbox/types.ts

export interface OutboxEvent {
  id: string;
  eventId: string;
  eventType: string;
  organizationId?: string;
  aggregateType?: string;
  aggregateId?: string;
  payload: unknown;
  status: 'PENDING' | 'PUBLISHING' | 'PUBLISHED' | 'FAILED' | 'DLQ';
  attemptCount: number;
  nextAttemptAt: Date | null;
  lastError?: string;
  createdAt: Date;
  publishedAt?: Date;
}

export interface EventBus {
  publish(event: PublishableEvent): Promise<void>;
}

export interface PublishableEvent {
  eventId: string;
  eventType: string;
  organizationId?: string;
  aggregateType?: string;
  aggregateId?: string;
  payload: unknown;
  occurredAt: Date;
}

export interface OutboxPublisherOptions {
  /** 한 번에 폴링할 row 수 (기본 100) */
  batchSize?: number;
  /** 폴링 간격 ms (기본 1000) */
  pollIntervalMs?: number;
  /** 재시도 정책 */
  retryPolicy?: RetryPolicy;
  /** DLQ 도달 임계 (기본 attemptCount >= 24) */
  dlqThreshold?: number;
}

export interface RetryPolicy {
  initialBackoffMs: number;     // 첫 재시도 (기본 1000)
  maxBackoffMs: number;          // 최대 (기본 5분 = 300_000)
  backoffMultiplier: number;     // 지수 (기본 2)
  jitterRatio?: number;          // 0~1 (기본 0.1)
}
```

## 2. 핵심 구현

```typescript
// business/_shared/outbox/publisher.ts

import { logger } from '../logger';
import { EventBus, OutboxEvent, OutboxPublisherOptions } from './types';

const DEFAULT_OPTIONS: Required<Omit<OutboxPublisherOptions, 'retryPolicy'>> & { retryPolicy: RetryPolicy } = {
  batchSize: 100,
  pollIntervalMs: 1000,
  dlqThreshold: 24,
  retryPolicy: {
    initialBackoffMs: 1000,
    maxBackoffMs: 300_000,
    backoffMultiplier: 2,
    jitterRatio: 0.1
  }
};

export class OutboxPublisher {
  private isRunning = false;
  private currentLoop: Promise<void> | null = null;

  constructor(
    private readonly db: PrismaClient,
    private readonly eventBus: EventBus,
    private readonly options: Required<OutboxPublisherOptions> = DEFAULT_OPTIONS as any
  ) {}

  start(): void {
    if (this.isRunning) return;
    this.isRunning = true;
    this.currentLoop = this.runLoop();
    logger.info('OutboxPublisher started');
  }

  async stop(): Promise<void> {
    this.isRunning = false;
    if (this.currentLoop) await this.currentLoop;
    logger.info('OutboxPublisher stopped');
  }

  private async runLoop(): Promise<void> {
    while (this.isRunning) {
      try {
        const processed = await this.tick();
        // 처리할 게 없으면 sleep, 있으면 즉시 다음 batch
        if (processed === 0) {
          await sleep(this.options.pollIntervalMs);
        }
      } catch (e) {
        logger.error('OutboxPublisher loop error', e);
        await sleep(this.options.pollIntervalMs * 5);  // 에러 시 백오프
      }
    }
  }

  /** 한 번 폴링 + 발행. 처리한 row 수 반환. */
  async tick(): Promise<number> {
    // 1. PENDING 또는 next_attempt_at <= now 인 FAILED row 폴링
    const candidates = await this.pollCandidates();
    if (candidates.length === 0) return 0;

    // 2. 각 row 발행 시도 (병렬 가능, 단순 직렬로 시작)
    let processed = 0;
    for (const row of candidates) {
      await this.publishOne(row);
      processed++;
    }
    return processed;
  }

  private async pollCandidates(): Promise<OutboxEvent[]> {
    // SELECT ... FOR UPDATE SKIP LOCKED — 분산 worker 안전
    const now = new Date();
    return await this.db.$queryRaw<OutboxEvent[]>`
      UPDATE event_outbox
         SET status = 'PUBLISHING', updated_at = NOW()
       WHERE id IN (
         SELECT id FROM event_outbox
          WHERE status IN ('PENDING', 'FAILED')
            AND (next_attempt_at IS NULL OR next_attempt_at <= ${now})
          ORDER BY created_at ASC
          LIMIT ${this.options.batchSize}
          FOR UPDATE SKIP LOCKED
       )
       RETURNING *;
    `;
  }

  private async publishOne(row: OutboxEvent): Promise<void> {
    try {
      await this.eventBus.publish({
        eventId: row.eventId,
        eventType: row.eventType,
        organizationId: row.organizationId,
        aggregateType: row.aggregateType,
        aggregateId: row.aggregateId,
        payload: row.payload,
        occurredAt: row.createdAt
      });

      // 성공
      await this.db.eventOutbox.update({
        where: { id: row.id },
        data: { status: 'PUBLISHED', publishedAt: new Date(), lastError: null }
      });
      metrics.outbox_published_count.inc({ event_type: row.eventType });
    } catch (e) {
      // 실패 → 재시도 / DLQ
      await this.handlePublishFailure(row, e as Error);
    }
  }

  private async handlePublishFailure(row: OutboxEvent, error: Error): Promise<void> {
    const newAttempt = row.attemptCount + 1;
    const isDlq = newAttempt >= this.options.dlqThreshold;

    if (isDlq) {
      await this.db.eventOutbox.update({
        where: { id: row.id },
        data: {
          status: 'DLQ',
          attemptCount: newAttempt,
          lastError: error.message
        }
      });
      logger.error(`Outbox event ${row.eventId} → DLQ (${newAttempt} attempts)`, error);
      metrics.outbox_dlq_count.inc({ event_type: row.eventType });
      await alertOps(`Outbox event DLQ: ${row.eventType} (${row.eventId})`);
      return;
    }

    // 재시도 — 지수 backoff + jitter
    const backoffMs = this.calculateBackoff(newAttempt);
    const nextAttemptAt = new Date(Date.now() + backoffMs);

    await this.db.eventOutbox.update({
      where: { id: row.id },
      data: {
        status: 'FAILED',
        attemptCount: newAttempt,
        nextAttemptAt,
        lastError: error.message
      }
    });
    logger.warn(`Outbox publish failed for ${row.eventId} (attempt ${newAttempt}, retry in ${backoffMs}ms)`);
    metrics.outbox_retry_count.inc({ event_type: row.eventType });
  }

  private calculateBackoff(attemptCount: number): number {
    const { initialBackoffMs, maxBackoffMs, backoffMultiplier, jitterRatio } = this.options.retryPolicy;
    const base = Math.min(
      initialBackoffMs * Math.pow(backoffMultiplier, attemptCount - 1),
      maxBackoffMs
    );
    const jitter = base * (jitterRatio ?? 0) * (Math.random() * 2 - 1);  // ±10%
    return Math.max(0, Math.round(base + jitter));
  }
}

// ─── 헬퍼 ────────────────────────────────────────────
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
```

## 3. 발행 트랜잭션 헬퍼

비즈니스 트랜잭션 안에서 outbox row INSERT 를 단순하게:

```typescript
// business/_shared/outbox/publish.ts

export async function publishToOutbox(
  tx: PrismaClient,
  event: {
    eventType: string;
    organizationId?: string;
    aggregateType?: string;
    aggregateId?: string;
    payload: unknown;
    correlationId?: string;
  }
): Promise<void> {
  await tx.eventOutbox.create({
    data: {
      eventId: crypto.randomUUID(),
      eventType: event.eventType,
      organizationId: event.organizationId,
      aggregateType: event.aggregateType,
      aggregateId: event.aggregateId,
      payload: event.payload,
      status: 'PENDING',
      attemptCount: 0,
      correlationId: event.correlationId,
      createdAt: new Date()
    }
  });
}
```

사용 예 (logistics delivery dispatch):

```typescript
// business/logistics/handlers/dispatch-delivery.ts
import { publishToOutbox } from '@erp-shared/outbox';

await db.$transaction(async (tx) => {
  await tx.delivery.update({
    where: { id: deliveryId },
    data: { status: 'IN_TRANSIT', dispatchedAt: new Date() }
  });

  await publishToOutbox(tx, {
    eventType: 'logistics.delivery.dispatched',
    organizationId: delivery.organizationId,
    aggregateType: 'delivery',
    aggregateId: deliveryId,
    payload: { deliveryId, dispatchedAt, items: /* ... */ }
  });
});
// 비즈니스 트랜잭션 commit → publisher worker 가 곧 발행
```

## 4. EventBus 어댑터

다양한 큐 시스템 어댑터:

```typescript
// business/_shared/outbox/event-bus.ts

// 1. 인메모리 (개발 / 테스트)
export class InMemoryEventBus implements EventBus {
  private subscribers = new Map<string, Array<(event: PublishableEvent) => Promise<void>>>();

  async publish(event: PublishableEvent): Promise<void> {
    const handlers = this.subscribers.get(event.eventType) ?? [];
    await Promise.all(handlers.map(h => h(event)));
  }

  subscribe(eventType: string, handler: (event: PublishableEvent) => Promise<void>) {
    const list = this.subscribers.get(eventType) ?? [];
    list.push(handler);
    this.subscribers.set(eventType, list);
  }
}

// 2. AWS SNS/SQS 어댑터 (운영) — 이미 v0.9.0 에 있음 (참고)
// 3. GCP Pub/Sub 어댑터 (운영) — 이미 v0.9.0 에 있음
// 4. BullMQ / Redis 어댑터 (Phase 1+ 옵션)
```

## 5. 운영 / 모니터링

### 5.1 메트릭

```
outbox_published_count{event_type}    — 성공 발행 수
outbox_retry_count{event_type}         — 재시도 수
outbox_dlq_count{event_type}           — DLQ 도달 수
outbox_pending_gauge                    — 현재 PENDING row 수
outbox_publish_latency_seconds_p95      — 발행 지연 (트랜잭션 commit → 발행)
```

### 5.2 알림 임계

| 메트릭 | 임계 | 알림 |
|---|---|---|
| `outbox_pending_gauge` > 1000 | 5분 | warn |
| `outbox_pending_gauge` > 10000 | 즉시 | critical |
| `outbox_dlq_count` increased | 즉시 | critical |
| `outbox_publish_latency_p95` > 30s | 10분 | warn |

### 5.3 운영 명령어 (CLI — 갭 07 참조)

```bash
# DLQ 재처리
erp-cli outbox dlq:list
erp-cli outbox dlq:retry <event-id>
erp-cli outbox dlq:purge --before 7d

# 통계
erp-cli outbox stats --since 1h
```

## 6. 테스트 시나리오

### 6.1 정상 발행

```typescript
test('outbox row → eventBus 발행', async () => {
  const bus = new InMemoryEventBus();
  const handler = vi.fn();
  bus.subscribe('test.event', handler);

  const publisher = new OutboxPublisher(db, bus);

  await db.eventOutbox.create({
    data: {
      eventId: 'evt-001', eventType: 'test.event',
      payload: { foo: 'bar' }, status: 'PENDING', attemptCount: 0
    }
  });

  await publisher.tick();

  expect(handler).toHaveBeenCalledWith(expect.objectContaining({
    eventId: 'evt-001', eventType: 'test.event'
  }));
  const row = await db.eventOutbox.findUnique({ where: { eventId: 'evt-001' }});
  expect(row?.status).toBe('PUBLISHED');
});
```

### 6.2 재시도 / 백오프

```typescript
test('실패 시 nextAttemptAt 갱신', async () => {
  const bus: EventBus = { publish: vi.fn().mockRejectedValue(new Error('boom')) };
  const publisher = new OutboxPublisher(db, bus);

  await db.eventOutbox.create({
    data: { eventId: 'evt-fail', eventType: 't', payload: {}, status: 'PENDING', attemptCount: 0 }
  });

  await publisher.tick();

  const row = await db.eventOutbox.findUnique({ where: { eventId: 'evt-fail' }});
  expect(row?.status).toBe('FAILED');
  expect(row?.attemptCount).toBe(1);
  expect(row?.nextAttemptAt).toBeInstanceOf(Date);
  expect(row?.lastError).toContain('boom');
});
```

### 6.3 DLQ 도달

```typescript
test('attemptCount >= dlqThreshold 시 DLQ', async () => {
  const publisher = new OutboxPublisher(db, failingBus, { dlqThreshold: 3 });

  await db.eventOutbox.create({
    data: { eventId: 'evt-dlq', eventType: 't', payload: {}, status: 'PENDING', attemptCount: 2 }
  });

  await publisher.tick();

  const row = await db.eventOutbox.findUnique({ where: { eventId: 'evt-dlq' }});
  expect(row?.status).toBe('DLQ');
});
```

### 6.4 분산 worker (SKIP LOCKED)

```typescript
test('동시 worker 가 같은 row 처리 X', async () => {
  // 100 row INSERT
  for (let i = 0; i < 100; i++) {
    await db.eventOutbox.create({ data: { /* ... */ }});
  }

  const pub1 = new OutboxPublisher(db, bus, { batchSize: 50 });
  const pub2 = new OutboxPublisher(db, bus, { batchSize: 50 });

  await Promise.all([pub1.tick(), pub2.tick()]);

  // 정확히 100 row publish — 중복 X
  expect(handler).toHaveBeenCalledTimes(100);
});
```

## 7. 통합 가이드

### 7.1 worker 배포

- 별도 컨테이너 / 프로세스로 실행 (web 서버와 분리)
- Replica 2+ (분산 처리, SKIP LOCKED 안전)
- graceful shutdown (`stop()` 호출 후 PENDING 처리 완료까지 대기)

### 7.2 룰 갱신

`.claude/rules/integration.md` § 1.1 갱신 — 이미 outbox 패턴 명시되어 있음. 추가:

```
> v0.3+: OutboxPublisher worker 가 별도 프로세스로 폴링 + 발행. SKIP LOCKED 로 분산 안전.
> 재시도 정책: 지수 backoff (1s → 5분 max), jitter ±10%, DLQ 임계 24회.
```

## 8. 검증 체크리스트

- [ ] `OutboxPublisher` 단위 테스트 통과
- [ ] InMemoryEventBus / AWS SNS / GCP PubSub 어댑터 동작
- [ ] SKIP LOCKED 분산 worker 안전
- [ ] 재시도 / DLQ / 메트릭 노출
- [ ] graceful shutdown
- [ ] 운영 CLI (`erp-cli outbox dlq:*`) — 갭 07
- [ ] `.claude/rules/integration.md` § 1.1 갱신

## 9. 참조

- 룰: `.claude/rules/integration.md` § 1.1 (outbox 패턴)
- 의존: 갭 01 (idempotency)
- 보강: 갭 03 (saga retry/backoff), 갭 07 (CLI), 갭 08 (README 정합)
