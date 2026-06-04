# 갭 05 — MemoryEventBus Flush 한계 해결

> **버전**: v0.3 진입 시 구현 (테스트 인프라 — 우선순위 중간)
> **위치**: `@erp-harness/core` 의 `InMemoryEventBus` 보강
> **영향**: 단위 / 통합 테스트, 개발 환경
> **의존**: 없음 (독립 작업)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- `InMemoryEventBus` 가 즉시 발행 + 즉시 처리 — 동기적
- `await bus.publish(event)` 가 모든 handler 의 처리 완료까지 기다림
- **flush / drain 메커니즘 부재** — 비동기 handler 가 setTimeout 등으로 지연 처리하면 테스트가 검증 불가
- saga / outbox 통합 테스트에서 "이벤트 발행 후 모든 부수 효과 완료" 보장 어려움

### 영향

- 통합 테스트가 flaky — `await sleep(100)` 같은 임의 대기로 회피 (안티패턴)
- 비동기 handler 체인 (이벤트 A → handler → 이벤트 B → handler) 검증 불완전
- 개발 환경에서 outbox publisher 가 InMemoryEventBus 발행 시점 정확히 추적 X

### 목표

- `bus.flush()` — 모든 진행 중 handler 완료까지 대기
- `bus.drain()` — 새 이벤트 받지 않고 기존만 처리
- 핸들러 체인 (이벤트가 다른 이벤트 발행) 도 추적
- 테스트 친화 (실패 캡처 / metrics 노출)

---

## 1. 인터페이스

```typescript
// business/_shared/event-bus/in-memory.ts

export interface PublishableEvent {
  eventId: string;
  eventType: string;
  organizationId?: string;
  payload: unknown;
  occurredAt: Date;
  correlationId?: string;
}

export interface EventHandler {
  (event: PublishableEvent): Promise<void>;
}

export interface InMemoryEventBusOptions {
  /** 핸들러 실행 모드 */
  mode?: 'sync' | 'queued';
  /** queued 모드: 동시 실행 한도 (기본 10) */
  concurrency?: number;
  /** flush 시 timeout (기본 30s) */
  flushTimeoutMs?: number;
  /** 핸들러 실패 시 동작 */
  onHandlerError?: 'throw' | 'log' | 'collect';
}

export interface FlushResult {
  processedCount: number;
  errors: Array<{ event: PublishableEvent; handlerName: string; error: Error }>;
  durationMs: number;
}
```

## 2. 핵심 구현

```typescript
// business/_shared/event-bus/in-memory.ts

const DEFAULT_OPTIONS: Required<InMemoryEventBusOptions> = {
  mode: 'queued',
  concurrency: 10,
  flushTimeoutMs: 30_000,
  onHandlerError: 'collect'
};

interface PendingTask {
  event: PublishableEvent;
  handler: EventHandler;
  handlerName: string;
}

export class InMemoryEventBus implements EventBus {
  private subscribers = new Map<string, Array<{ handler: EventHandler; name: string }>>();
  private pending: Set<Promise<void>> = new Set();
  private collectedErrors: FlushResult['errors'] = [];
  private isDraining = false;
  private isClosed = false;
  private readonly options: Required<InMemoryEventBusOptions>;

  constructor(options: InMemoryEventBusOptions = {}) {
    this.options = { ...DEFAULT_OPTIONS, ...options };
  }

  subscribe(eventType: string, handler: EventHandler, name?: string): () => void {
    const list = this.subscribers.get(eventType) ?? [];
    const entry = { handler, name: name ?? `handler_${list.length}` };
    list.push(entry);
    this.subscribers.set(eventType, list);
    // unsubscribe 함수 반환
    return () => {
      const idx = list.indexOf(entry);
      if (idx >= 0) list.splice(idx, 1);
    };
  }

  async publish(event: PublishableEvent): Promise<void> {
    if (this.isClosed) {
      throw new Error('InMemoryEventBus is closed');
    }
    if (this.isDraining) {
      throw new Error('InMemoryEventBus is draining — no new events accepted');
    }

    const handlers = this.subscribers.get(event.eventType) ?? [];
    if (handlers.length === 0) {
      logger.debug(`No handlers for ${event.eventType}`);
      return;
    }

    if (this.options.mode === 'sync') {
      // 즉시 동기적 실행 (기존 v0.9.0 동작)
      await this.executeHandlers(event, handlers);
    } else {
      // queued: 백그라운드 실행, flush() 가 기다림
      const tasks = handlers.map(({ handler, name }) => ({ event, handler, handlerName: name }));
      for (const task of tasks) {
        this.enqueueTask(task);
      }
    }
  }

  private enqueueTask(task: PendingTask): void {
    const promise = this.executeTaskWithLimit(task);
    this.pending.add(promise);
    promise.finally(() => this.pending.delete(promise));
  }

  private async executeTaskWithLimit(task: PendingTask): Promise<void> {
    // 동시 실행 한도 (semaphore)
    while (this.pendingCount() >= this.options.concurrency) {
      await this.waitOne();
    }

    try {
      await task.handler(task.event);
      metrics.event_handler_processed.inc({ event_type: task.event.eventType, handler: task.handlerName });
    } catch (e) {
      metrics.event_handler_failed.inc({ event_type: task.event.eventType, handler: task.handlerName });
      const error = e as Error;
      if (this.options.onHandlerError === 'throw') {
        throw error;
      }
      this.collectedErrors.push({ event: task.event, handlerName: task.handlerName, error });
      if (this.options.onHandlerError === 'log') {
        logger.error(`Handler ${task.handlerName} failed for ${task.event.eventType}`, error);
      }
    }
  }

  /** 모든 진행 중 핸들러 완료까지 대기. 실패 모음 반환. */
  async flush(timeoutMs?: number): Promise<FlushResult> {
    const startedAt = Date.now();
    const timeout = timeoutMs ?? this.options.flushTimeoutMs;
    const initialErrors = this.collectedErrors.length;
    const initialProcessed = metrics.event_handler_processed.value();

    // 새 이벤트가 핸들러에서 또 발행될 수 있으므로 — pending 이 비워질 때까지 반복
    const deadline = Date.now() + timeout;
    while (this.pending.size > 0) {
      if (Date.now() > deadline) {
        throw new FlushTimeoutError(`flush timeout after ${timeout}ms (${this.pending.size} pending)`);
      }
      await Promise.race([
        Promise.all(this.pending),
        sleep(100)  // periodic check
      ]);
    }

    const durationMs = Date.now() - startedAt;
    const result: FlushResult = {
      processedCount: metrics.event_handler_processed.value() - initialProcessed,
      errors: this.collectedErrors.slice(initialErrors),
      durationMs
    };
    return result;
  }

  /** 새 이벤트 받지 않고 기존만 완료. shutdown 용. */
  async drain(timeoutMs?: number): Promise<FlushResult> {
    this.isDraining = true;
    try {
      return await this.flush(timeoutMs);
    } finally {
      this.isDraining = false;
    }
  }

  /** 완전 종료 — 새 이벤트 거부 + 기존 처리 완료 대기 */
  async close(timeoutMs?: number): Promise<FlushResult> {
    const result = await this.drain(timeoutMs);
    this.isClosed = true;
    return result;
  }

  /** 테스트용 — 수집된 에러 확인 후 reset */
  drainErrors(): FlushResult['errors'] {
    const errors = this.collectedErrors.slice();
    this.collectedErrors = [];
    return errors;
  }

  pendingCount(): number {
    return this.pending.size;
  }

  // 내부 헬퍼
  private async executeHandlers(
    event: PublishableEvent,
    handlers: Array<{ handler: EventHandler; name: string }>
  ): Promise<void> {
    for (const { handler, name } of handlers) {
      try {
        await handler(event);
      } catch (e) {
        if (this.options.onHandlerError === 'throw') throw e;
        this.collectedErrors.push({ event, handlerName: name, error: e as Error });
      }
    }
  }

  private async waitOne(): Promise<void> {
    if (this.pending.size === 0) return;
    await Promise.race([...this.pending].map(p => p.catch(() => {})));
  }
}

class FlushTimeoutError extends Error {}
```

## 3. 사용 예시

### 3.1 일반 발행

```typescript
const bus = new InMemoryEventBus({ mode: 'queued' });

bus.subscribe('logistics.delivery.dispatched', async (event) => {
  // inventory OUT movement
  await createInventoryMovement(/* ... */);
});

await bus.publish({
  eventId: 'evt-1',
  eventType: 'logistics.delivery.dispatched',
  payload: { /* ... */ },
  occurredAt: new Date()
});

// 백그라운드 실행 — 호출자는 즉시 반환
```

### 3.2 테스트 — flush

```typescript
test('cross-module 이벤트 흐름', async () => {
  const bus = new InMemoryEventBus({ onHandlerError: 'collect' });

  // 핸들러 등록
  bus.subscribe('logistics.delivery.completed', payrollWorkLogHandler);
  bus.subscribe('payroll.work_log.confirmed', reportsCacheInvalidator);

  // 시작 이벤트 발행
  await bus.publish({
    eventId: 'evt-test',
    eventType: 'logistics.delivery.completed',
    payload: { deliveryId: 'd-1', driverId: 'u-1' },
    occurredAt: new Date()
  });

  // 모든 부수 효과 완료까지 대기
  const result = await bus.flush();

  expect(result.errors).toHaveLength(0);
  expect(result.processedCount).toBeGreaterThan(0);

  // 검증
  const workLog = await db.workLog.findFirst({ where: { sourceId: 'd-1' }});
  expect(workLog).toBeDefined();
});
```

### 3.3 graceful shutdown

```typescript
// app/server.ts
process.on('SIGTERM', async () => {
  logger.info('Draining event bus...');
  const result = await bus.close(60_000);   // 60s timeout
  if (result.errors.length > 0) {
    logger.error(`Drain completed with ${result.errors.length} errors`, result.errors);
  }
  await db.$disconnect();
});
```

## 4. 핸들러 체인 추적

이벤트 A → 핸들러 → 이벤트 B → 핸들러 → ... 까지 모두 flush 대기:

```typescript
test('이벤트 체인 모두 처리', async () => {
  const bus = new InMemoryEventBus();

  bus.subscribe('A', async (event) => {
    await bus.publish({ ...event, eventType: 'B', eventId: 'b-1' });
  });
  bus.subscribe('B', async (event) => {
    await bus.publish({ ...event, eventType: 'C', eventId: 'c-1' });
  });
  const cHandler = vi.fn();
  bus.subscribe('C', cHandler);

  await bus.publish({ eventType: 'A', eventId: 'a-1', payload: {}, occurredAt: new Date() });
  await bus.flush();

  expect(cHandler).toHaveBeenCalled();
});
```

핵심: `pending` 이 비워질 때까지 loop — 핸들러가 새로 발행한 이벤트도 pending 에 추가됨.

## 5. 테스트 시나리오

### 5.1 정상 flush

```typescript
test('flush 후 모든 핸들러 완료', async () => {
  const bus = new InMemoryEventBus();
  const handler = vi.fn().mockImplementation(() => sleep(50));
  bus.subscribe('test', handler);

  for (let i = 0; i < 10; i++) {
    await bus.publish({ eventType: 'test', eventId: `e-${i}`, payload: {}, occurredAt: new Date() });
  }

  expect(bus.pendingCount()).toBeGreaterThan(0);
  await bus.flush();
  expect(bus.pendingCount()).toBe(0);
  expect(handler).toHaveBeenCalledTimes(10);
});
```

### 5.2 동시성 한도

```typescript
test('concurrency 한도 준수', async () => {
  const bus = new InMemoryEventBus({ concurrency: 3 });
  const inFlight = new Set<number>();
  let maxInFlight = 0;

  bus.subscribe('test', async (event) => {
    inFlight.add(event.eventId as any);
    maxInFlight = Math.max(maxInFlight, inFlight.size);
    await sleep(20);
    inFlight.delete(event.eventId as any);
  });

  for (let i = 0; i < 10; i++) {
    await bus.publish({ eventType: 'test', eventId: i as any, payload: {}, occurredAt: new Date() });
  }
  await bus.flush();

  expect(maxInFlight).toBeLessThanOrEqual(3);
});
```

### 5.3 flush timeout

```typescript
test('flush timeout 시 throw', async () => {
  const bus = new InMemoryEventBus();
  bus.subscribe('slow', async () => sleep(60_000));

  await bus.publish({ eventType: 'slow', eventId: 's-1', payload: {}, occurredAt: new Date() });

  await expect(bus.flush(1000)).rejects.toThrow(/flush timeout/);
});
```

### 5.4 drain — 새 이벤트 거부

```typescript
test('drain 중 publish → throw', async () => {
  const bus = new InMemoryEventBus();
  bus.subscribe('test', async () => sleep(100));
  await bus.publish({ eventType: 'test', /* ... */ });

  const drainPromise = bus.drain();
  await expect(
    bus.publish({ eventType: 'test', /* ... */ })
  ).rejects.toThrow(/draining/);

  await drainPromise;
});
```

## 6. 통합 가이드

### 6.1 테스트 헬퍼

```typescript
// __tests__/helpers/test-bus.ts
export function createTestBus(): InMemoryEventBus {
  return new InMemoryEventBus({
    mode: 'queued',
    concurrency: 5,
    flushTimeoutMs: 5000,
    onHandlerError: 'collect'
  });
}

export async function publishAndFlush(bus: InMemoryEventBus, event: PublishableEvent) {
  await bus.publish(event);
  return await bus.flush();
}
```

모든 통합 테스트가 `await sleep(100)` 대신 `await bus.flush()` 사용.

### 6.2 룰 갱신

`.claude/rules/integration.md` § 4 (테스트 / 관측) 추가:

```
## 4.4 테스트 — 이벤트 흐름 검증

InMemoryEventBus 의 flush() 사용. 임의 sleep 금지.

```typescript
await bus.publish(event);
const result = await bus.flush();
expect(result.errors).toHaveLength(0);
```

## 7. 검증 체크리스트

- [ ] flush() 단위 테스트 (정상 / timeout / 체인)
- [ ] drain() 단위 테스트
- [ ] concurrency 한도 검증
- [ ] 핸들러 체인 추적 검증
- [ ] 모든 통합 테스트의 `sleep` → `flush` 마이그레이션
- [ ] graceful shutdown 통합 (`close()`)

## 8. 참조

- 의존: 없음 (독립)
- 보강: 갭 02 (outbox publisher 와 결합 시 InMemoryEventBus 사용)
- 룰: `.claude/rules/integration.md` § 4 (관측 / 테스트)
