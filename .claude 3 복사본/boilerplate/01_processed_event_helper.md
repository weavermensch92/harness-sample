# 갭 01 — ProcessedEvent 멱등 헬퍼

> **버전**: v0.2 → 0.3 진입 시 우선 구현
> **위치**: `@erp-harness/core` 또는 `business/_shared/`
> **영향**: 모든 모듈의 이벤트 핸들러 (payroll / inventory / logistics / reports)
> **의존**: `processed_events` 테이블 (스키마는 v0.9.0 에 존재)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- `processed_events` 테이블은 정의되어 있음
- 각 핸들러가 개별적으로 멱등 가드 작성 — 패턴 분산, 에러 처리 비일관
- 멱등 위반 시 동작이 일관되지 않음 (skip vs throw vs silent fail)

### 영향

- 새 핸들러 작성 시 멱등 패턴 매번 재작성 → 누락 위험
- 분산 환경에서 같은 이벤트 동시 도착 시 race condition
- 디버그 시 멱등 동작 추적 어려움

### 목표

단일 헬퍼 — `withIdempotency(eventId, fn)` — 모든 핸들러가 일관된 멱등 처리.

---

## 1. 인터페이스

```typescript
// business/_shared/idempotency.ts

export interface ProcessedEvent {
  eventId: string;        // UUID
  eventType: string;
  organizationId?: string;
  processedAt: Date;
}

export interface IdempotencyOptions {
  /** 이미 처리된 경우 동작:
   *   - 'skip': 조용히 skip (기본)
   *   - 'log_and_skip': warn 로그 후 skip
   *   - 'return_cached': 캐시 결과 반환 (cachedResult 필요)
   */
  onDuplicate?: 'skip' | 'log_and_skip' | 'return_cached';
  /** TTL — 이 시간 이후 같은 eventId 재처리 허용 (기본 영구) */
  ttlSeconds?: number;
}

export interface IdempotencyResult<T> {
  isFirst: boolean;       // 처음 처리 여부
  result?: T;             // 처리 결과 (isFirst=true 일 때만)
}
```

## 2. 핵심 구현

```typescript
// business/_shared/idempotency.ts

import type { PrismaClient } from '@prisma/client';
import { logger } from './logger';

/**
 * 멱등 가드 헬퍼.
 * - 같은 eventId 가 이미 처리되었으면 skip
 * - 처음이면 fn() 실행 + processedEvent INSERT (같은 트랜잭션)
 * - DB 의 UNIQUE 제약을 신뢰 — race condition 시 catch
 */
export async function withIdempotency<T>(
  tx: PrismaClient | Omit<PrismaClient, '$transaction' | '$disconnect' | '$connect'>,
  event: { eventId: string; eventType: string; organizationId?: string },
  fn: (tx: typeof prismaArg) => Promise<T>,
  options: IdempotencyOptions = {}
): Promise<IdempotencyResult<T>> {
  const { onDuplicate = 'skip' } = options;

  try {
    // INSERT 먼저 — UNIQUE 위반이면 이미 처리됨
    await tx.processedEvent.create({
      data: {
        eventId: event.eventId,
        eventType: event.eventType,
        organizationId: event.organizationId,
        processedAt: new Date()
      }
    });
  } catch (e) {
    if (isUniqueViolation(e)) {
      // 이미 처리됨
      if (onDuplicate === 'log_and_skip') {
        logger.warn(`Idempotency: event ${event.eventId} already processed (skip)`);
      }
      return { isFirst: false };
    }
    throw e;
  }

  // 처음 처리
  try {
    const result = await fn(tx as PrismaClient);
    return { isFirst: true, result };
  } catch (e) {
    // fn 실패 → processedEvent 도 롤백 (외부 트랜잭션 의존)
    // 같은 트랜잭션 안에서 호출되므로 자동 롤백됨
    throw e;
  }
}

/**
 * 자연 키 멱등 + eventId 멱등 (2중 방어)
 * — 자연 키는 도메인 모델의 UNIQUE (예: source_type + source_id)
 * — eventId 는 이벤트 발행 단위
 */
export async function withDualIdempotency<T>(
  tx: PrismaClient,
  event: { eventId: string; eventType: string; organizationId?: string },
  naturalKeyFn: () => Promise<{ exists: boolean; existing?: T }>,
  fn: () => Promise<T>
): Promise<IdempotencyResult<T>> {
  // 1. 자연 키 검사 먼저 (빠른 short-circuit)
  const natural = await naturalKeyFn();
  if (natural.exists) {
    return { isFirst: false, result: natural.existing };
  }

  // 2. eventId 멱등
  return withIdempotency(tx, event, fn);
}

// ─── 헬퍼 ────────────────────────────────────────────
function isUniqueViolation(e: unknown): boolean {
  // Prisma: P2002 / 일반 PG: 23505
  return typeof e === 'object' && e !== null && (
    ('code' in e && e.code === 'P2002') ||
    ('code' in e && e.code === '23505')
  );
}
```

## 3. 사용 예시 (모듈별)

### 3.1 logistics — DELIVERY_DISPATCHED 핸들러 (inventory OUT)

```typescript
// business/inventory/handlers/delivery-dispatched-handler.ts
import { withDualIdempotency } from '@erp-shared/idempotency';

export async function handleDeliveryDispatched(event: DeliveryDispatchedEvent) {
  await db.$transaction(async (tx) => {
    await withDualIdempotency(
      tx,
      event,
      // 자연 키: (org, source_type, source_id) UNIQUE
      async () => {
        const existing = await tx.inventoryMovement.findFirst({
          where: {
            organizationId: event.organizationId,
            sourceType: 'DELIVERY',
            sourceId: event.deliveryId
          }
        });
        return { exists: !!existing, existing };
      },
      // 처음 처리 시 OUT movement 생성
      async () => {
        return await tx.inventoryMovement.create({
          data: {
            organizationId: event.organizationId,
            warehouseId: event.warehouseId,
            itemId: event.items[0].itemId,
            direction: 'OUT',
            qty: event.items[0].qty,
            signedQty: -event.items[0].qty,
            sourceType: 'DELIVERY',
            sourceId: event.deliveryId,
            occurredAt: new Date(event.dispatchedAt),
            createdBy: SYSTEM_USER_ID
          }
        });
      }
    );
  });
}
```

### 3.2 payroll — DELIVERY_COMPLETED 핸들러 (work_log)

```typescript
// business/payroll/handlers/delivery-completed-handler.ts
import { withIdempotency } from '@erp-shared/idempotency';

export async function handleDeliveryCompleted(event: DeliveryCompletedEvent) {
  if (!event.driverId) return; // 외부 carrier 는 work_log X

  await db.$transaction(async (tx) => {
    const result = await withIdempotency(
      tx,
      event,
      async () => {
        const amount = await calculateDriverWage(event, tx);
        return await tx.workLog.create({
          data: {
            userId: event.driverId,
            sourceType: 'DELIVERY',
            sourceId: event.deliveryId,
            amount,
            occurredAt: new Date(event.completedAt)
          }
        });
      },
      { onDuplicate: 'log_and_skip' }
    );

    if (result.isFirst) {
      logger.info(`WorkLog created for delivery ${event.deliveryId}`);
    }
  });
}
```

## 4. 테스트 시나리오

### 4.1 단일 처리

```typescript
// __tests__/idempotency.test.ts
test('처음 이벤트는 fn 실행', async () => {
  const result = await withIdempotency(
    db,
    { eventId: 'evt-001', eventType: 'test.event' },
    async () => 'processed'
  );
  expect(result.isFirst).toBe(true);
  expect(result.result).toBe('processed');
});

test('중복 이벤트는 skip', async () => {
  const event = { eventId: 'evt-002', eventType: 'test.event' };
  const fn = vi.fn().mockResolvedValue('processed');

  await withIdempotency(db, event, fn);
  const result = await withIdempotency(db, event, fn);

  expect(result.isFirst).toBe(false);
  expect(fn).toHaveBeenCalledTimes(1);  // 한 번만 실행됨
});
```

### 4.2 동시 도착 (race condition)

```typescript
test('동시 호출 시 정확히 한 번만 처리', async () => {
  const event = { eventId: 'evt-race', eventType: 'test.event' };
  const fn = vi.fn().mockResolvedValue('done');

  const results = await Promise.all([
    withIdempotency(db, event, fn),
    withIdempotency(db, event, fn),
    withIdempotency(db, event, fn)
  ]);

  const firstCount = results.filter(r => r.isFirst).length;
  expect(firstCount).toBe(1);  // 정확히 한 번만 isFirst=true
  expect(fn).toHaveBeenCalledTimes(1);
});
```

### 4.3 fn 실패 시 롤백

```typescript
test('fn 실패 시 processedEvent 도 롤백', async () => {
  const event = { eventId: 'evt-fail', eventType: 'test.event' };

  await expect(
    db.$transaction(async (tx) => {
      await withIdempotency(tx, event, async () => {
        throw new Error('처리 실패');
      });
    })
  ).rejects.toThrow();

  // processedEvent INSERT 도 롤백 → 재시도 가능
  const exists = await db.processedEvent.findUnique({ where: { eventId: 'evt-fail' }});
  expect(exists).toBeNull();
});
```

## 5. 통합 가이드

### 5.1 기존 핸들러 마이그레이션

기존 패턴:
```typescript
// 분산된 패턴 (현재)
const exists = await db.processedEvent.findUnique({ where: { eventId }});
if (exists) return;
await db.processedEvent.create({ data: { eventId } });
// ... 본 로직
```

새 패턴:
```typescript
// 통일된 패턴 (이후)
await withIdempotency(tx, event, async () => { /* 본 로직 */ });
```

### 5.2 이벤트 핸들러 작성 표준 (룰)

`.claude/rules/integration.md` § 1.3 갱신:

```
## 1.3 멱등 처리 (MUST)
모든 이벤트 핸들러는 @erp-shared/idempotency 의 withIdempotency / withDualIdempotency 헬퍼 사용.
직접 processed_events 테이블 조작 금지.
자연 키 멱등이 가능한 경우 withDualIdempotency 우선 사용.
```

### 5.3 메트릭

```typescript
// 멱등 관련 메트릭 (Prometheus / Datadog)
- idempotency.duplicate_count (label: eventType)
- idempotency.first_count
- idempotency.race_condition_count (UNIQUE 위반 catch)
```

## 6. 검증 체크리스트

- [ ] `withIdempotency` 단위 테스트 통과
- [ ] `withDualIdempotency` 단위 테스트 통과
- [ ] race condition 테스트 통과 (3+ 동시 호출)
- [ ] fn 실패 시 롤백 검증
- [ ] 모든 모듈의 외부 이벤트 핸들러가 헬퍼 사용
- [ ] 메트릭 노출 (duplicate_count 등)
- [ ] `rules/integration.md` § 1.3 갱신

## 7. 참조

- 룰: `.claude/rules/integration.md` § 1.3 (멱등)
- DB: `.claude/rules/database.md` § 4.3 (멱등 키 = UNIQUE)
- 사용처:
  - `inventory/rules/stock_movement.md` § EI-110 (movement 멱등)
  - `logistics/rules/delivery.md` § EL-030 (delivery 멱등)
  - `logistics/rules/tracking_pod.md` § EL-318 (carrier 콜백 멱등)
  - `payroll/rules/work_log.md` § EP-130 (work_log 멱등)
  - `reports/rules/report_generation.md` § ER-150 (cache 키)
