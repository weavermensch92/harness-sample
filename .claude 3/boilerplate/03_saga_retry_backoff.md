# 갭 03 — Saga Retry / Backoff 정책

> **버전**: v0.3 진입 시 구현
> **위치**: `@erp-harness/core` saga 모듈 보강
> **영향**: 분산 트랜잭션 복구 (logistics ↔ inventory ↔ payroll)
> **의존**: 갭 01 (idempotency), 갭 02 (outbox)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- Saga 퍼시스턴스 (`DbSagaLogger`) 존재 — saga step 이력 보존
- **재시도 / backoff 정책 부재** — step 실패 시 그냥 멈추거나 즉시 보상 트랜잭션
- 일시적 실패 (네트워크 / 외부 API timeout) 와 영구 실패 구분 X

### 영향

- 외부 API 일시 장애 시 saga 가 즉시 보상 → 데이터 일관성 우선이지만 복구 가능 케이스도 보상됨
- 실패 패턴 분석 어려움 (지수 backoff 없으면 thunder herd)
- 운영자가 수동으로 saga resume 하기 어려움

### 목표

step 실패 시 retry policy 에 따라 자동 재시도 → 임계 도달 시에만 보상 트랜잭션. 명확한 retry vs compensate 구분.

---

## 1. 인터페이스

```typescript
// business/_shared/saga/types.ts

export interface SagaStep<TInput, TOutput> {
  name: string;
  execute: (input: TInput) => Promise<TOutput>;
  compensate?: (input: TInput, output?: TOutput) => Promise<void>;
  retryPolicy?: StepRetryPolicy;
}

export interface StepRetryPolicy {
  maxAttempts: number;              // 기본 3
  initialBackoffMs: number;          // 기본 1000
  maxBackoffMs: number;              // 기본 30_000
  backoffMultiplier: number;         // 기본 2
  jitterRatio?: number;              // 0~1 기본 0.1
  // 어떤 에러는 재시도 X (즉시 보상)
  isRetryable?: (error: unknown) => boolean;
}

export interface SagaState {
  sagaId: string;
  status: 'RUNNING' | 'COMPENSATING' | 'COMPLETED' | 'FAILED' | 'COMPENSATED';
  currentStep: string | null;
  attemptCount: number;              // 현재 step 의 재시도 횟수
  nextRetryAt?: Date;
  startedAt: Date;
  completedAt?: Date;
  context: Record<string, unknown>;
}

export interface SagaStepLog {
  sagaId: string;
  stepName: string;
  status: 'STARTED' | 'SUCCEEDED' | 'FAILED' | 'COMPENSATED';
  attemptCount: number;
  startedAt: Date;
  completedAt?: Date;
  input: unknown;
  output?: unknown;
  error?: string;
}
```

## 2. 핵심 구현

```typescript
// business/_shared/saga/saga-runner.ts

const DEFAULT_RETRY_POLICY: StepRetryPolicy = {
  maxAttempts: 3,
  initialBackoffMs: 1000,
  maxBackoffMs: 30_000,
  backoffMultiplier: 2,
  jitterRatio: 0.1,
  isRetryable: (e) => isTransientError(e)
};

export class SagaRunner {
  constructor(
    private readonly db: PrismaClient,
    private readonly sagaLogger: ISagaLogger
  ) {}

  async run<T>(
    sagaId: string,
    steps: SagaStep<any, any>[],
    initialInput: T
  ): Promise<unknown> {
    let state = await this.loadOrCreateSagaState(sagaId, initialInput);
    let context = state.context;

    // 시작 step 결정 (resume 케이스: currentStep 부터)
    const startIndex = state.currentStep
      ? steps.findIndex(s => s.name === state.currentStep)
      : 0;

    if (startIndex < 0) {
      throw new Error(`Saga ${sagaId}: currentStep ${state.currentStep} not found in steps`);
    }

    // step 순차 실행
    for (let i = startIndex; i < steps.length; i++) {
      const step = steps[i];
      try {
        const result = await this.executeStepWithRetry(state, step, context);
        context[step.name] = result;

        // step 성공 → state 갱신
        state = await this.updateState(sagaId, {
          currentStep: i + 1 < steps.length ? steps[i + 1].name : null,
          attemptCount: 0,
          context
        });
      } catch (e) {
        // 재시도 한도 도달 → 보상 트랜잭션
        await this.compensate(sagaId, steps, i, context, e as Error);
        throw new SagaFailedError(sagaId, step.name, e);
      }
    }

    // 모든 step 완료
    await this.updateState(sagaId, { status: 'COMPLETED', completedAt: new Date() });
    return context;
  }

  private async executeStepWithRetry(
    state: SagaState,
    step: SagaStep<any, any>,
    context: Record<string, unknown>
  ): Promise<unknown> {
    const policy = step.retryPolicy ?? DEFAULT_RETRY_POLICY;
    let attempt = state.attemptCount;
    let lastError: Error | undefined;

    while (attempt < policy.maxAttempts) {
      attempt++;

      // step 시작 로그
      await this.sagaLogger.logStepStart(state.sagaId, step.name, attempt, context);

      try {
        const result = await step.execute(context);
        await this.sagaLogger.logStepSuccess(state.sagaId, step.name, attempt, result);
        return result;
      } catch (e) {
        lastError = e as Error;
        await this.sagaLogger.logStepFailure(state.sagaId, step.name, attempt, lastError);

        const retryable = policy.isRetryable?.(e) ?? false;
        if (!retryable) {
          // 영구 실패 — 즉시 보상으로 진행
          throw new NonRetryableStepError(step.name, lastError);
        }

        if (attempt >= policy.maxAttempts) {
          // 재시도 한도 도달
          throw new RetryExhaustedError(step.name, attempt, lastError);
        }

        // 재시도 대기
        const backoffMs = this.calculateBackoff(policy, attempt);
        await this.updateState(state.sagaId, {
          attemptCount: attempt,
          nextRetryAt: new Date(Date.now() + backoffMs)
        });
        logger.info(`Saga ${state.sagaId}: step ${step.name} retry in ${backoffMs}ms (attempt ${attempt})`);
        await sleep(backoffMs);
      }
    }
    throw lastError ?? new Error('Unexpected saga state');
  }

  private async compensate(
    sagaId: string,
    steps: SagaStep<any, any>[],
    failedStepIndex: number,
    context: Record<string, unknown>,
    originalError: Error
  ): Promise<void> {
    await this.updateState(sagaId, { status: 'COMPENSATING' });
    logger.warn(`Saga ${sagaId}: compensating from step ${steps[failedStepIndex].name}`);

    // 실패한 step 부터 역순으로 compensate (이미 완료된 step 부터)
    for (let i = failedStepIndex - 1; i >= 0; i--) {
      const step = steps[i];
      if (!step.compensate) continue;
      try {
        await step.compensate(context, context[step.name]);
        await this.sagaLogger.logCompensation(sagaId, step.name, 'SUCCEEDED');
      } catch (e) {
        // 보상 자체가 실패 — 위험. 운영자 개입 필요.
        await this.sagaLogger.logCompensation(sagaId, step.name, 'FAILED', e as Error);
        await alertOps(`Saga ${sagaId}: compensation failed at ${step.name}`, e);
      }
    }

    await this.updateState(sagaId, {
      status: 'COMPENSATED',
      completedAt: new Date()
    });
  }

  private calculateBackoff(policy: StepRetryPolicy, attempt: number): number {
    const base = Math.min(
      policy.initialBackoffMs * Math.pow(policy.backoffMultiplier, attempt - 1),
      policy.maxBackoffMs
    );
    const jitter = base * (policy.jitterRatio ?? 0) * (Math.random() * 2 - 1);
    return Math.max(0, Math.round(base + jitter));
  }

  private async loadOrCreateSagaState(sagaId: string, initialInput: unknown): Promise<SagaState> {
    const existing = await this.db.sagaState.findUnique({ where: { sagaId }});
    if (existing) return existing as SagaState;
    return await this.db.sagaState.create({
      data: {
        sagaId,
        status: 'RUNNING',
        currentStep: null,
        attemptCount: 0,
        startedAt: new Date(),
        context: { input: initialInput }
      }
    });
  }

  private async updateState(sagaId: string, patch: Partial<SagaState>): Promise<SagaState> {
    return await this.db.sagaState.update({ where: { sagaId }, data: patch }) as SagaState;
  }
}
```

## 3. 재시도 vs 보상 분류

### 3.1 재시도 가능 (transient)

기본 분류:
```typescript
function isTransientError(e: unknown): boolean {
  if (e instanceof NetworkError) return true;
  if (e instanceof TimeoutError) return true;
  if (e instanceof DatabaseDeadlockError) return true;
  if (isHttpError(e) && [502, 503, 504].includes(e.status)) return true;
  return false;
}
```

도메인 케이스:
- carrier API timeout / 5xx
- DB deadlock
- 외부 결제 시스템 일시 장애
- 메일 ESP 일시 거부 (rate limit)

### 3.2 즉시 보상 (permanent)

- 4xx (입력 검증 실패) — 재시도해도 동일
- `InsufficientPermissionError` — 권한 변경 필요
- `BalanceInsufficientError` — 재고 부족 (보상 후 운영자 개입)
- `InvalidStateTransitionError` — 비즈니스 규칙 위반

## 4. 사용 예시 — ORDER_CONFIRMED saga

```typescript
// business/logistics/sagas/order-confirmed-saga.ts

const orderConfirmedSaga = (event: OrderConfirmedEvent) => [
  // Step 1: Delivery DRAFT 생성
  {
    name: 'create_delivery_draft',
    execute: async (ctx) => {
      const delivery = await db.delivery.create({
        data: { /* ... */, status: 'DRAFT' }
      });
      return { deliveryId: delivery.id };
    },
    compensate: async (ctx) => {
      // 보상: delivery 삭제
      if (ctx.create_delivery_draft?.deliveryId) {
        await db.delivery.delete({ where: { id: ctx.create_delivery_draft.deliveryId }});
      }
    },
    retryPolicy: {
      maxAttempts: 5,
      initialBackoffMs: 500,
      maxBackoffMs: 10_000,
      backoffMultiplier: 2,
      isRetryable: (e) => isTransientError(e) || e instanceof DatabaseDeadlockError
    }
  } as SagaStep<OrderConfirmedEvent, { deliveryId: string }>,

  // Step 2: inventory reservation 생성
  {
    name: 'create_reservation',
    execute: async (ctx) => {
      const res = await db.inventoryReservation.create({
        data: { /* ... */ }
      });
      return { reservationId: res.id };
    },
    compensate: async (ctx) => {
      if (ctx.create_reservation?.reservationId) {
        await db.inventoryReservation.update({
          where: { id: ctx.create_reservation.reservationId },
          data: { status: 'RELEASED', releasedAt: new Date() }
        });
      }
    }
    // 기본 retry 정책
  },

  // Step 3: outbox 이벤트 발행
  {
    name: 'publish_drafted',
    execute: async (ctx) => {
      await publishToOutbox(db, {
        eventType: 'logistics.delivery.drafted',
        aggregateId: ctx.create_delivery_draft.deliveryId,
        payload: { /* ... */ }
      });
      return { published: true };
    }
    // compensate 없음 — outbox 는 자체 멱등
  }
];

// 실행
const runner = new SagaRunner(db, new DbSagaLogger());
await runner.run(`saga:order:${event.orderId}`, orderConfirmedSaga(event), event);
```

## 5. 테스트 시나리오

### 5.1 정상 완료

```typescript
test('모든 step 성공 → COMPLETED', async () => {
  const steps = [
    { name: 'a', execute: async () => ({ a: 1 }) },
    { name: 'b', execute: async () => ({ b: 2 }) }
  ];
  const result = await runner.run('saga-001', steps, {});
  const state = await db.sagaState.findUnique({ where: { sagaId: 'saga-001' }});
  expect(state?.status).toBe('COMPLETED');
});
```

### 5.2 재시도 후 성공

```typescript
test('일시적 실패 후 재시도 성공', async () => {
  let attempts = 0;
  const steps = [{
    name: 'flaky',
    execute: async () => {
      attempts++;
      if (attempts < 3) throw new NetworkError('boom');
      return { ok: true };
    },
    retryPolicy: { maxAttempts: 5, initialBackoffMs: 10 /* fast for test */ }
  }];

  await runner.run('saga-retry', steps, {});
  expect(attempts).toBe(3);
});
```

### 5.3 재시도 한도 → 보상

```typescript
test('재시도 한도 도달 → COMPENSATED', async () => {
  const compensateA = vi.fn();
  const steps = [
    {
      name: 'a',
      execute: async () => ({ a: 1 }),
      compensate: compensateA
    },
    {
      name: 'b',
      execute: async () => { throw new NetworkError('always fails'); },
      retryPolicy: { maxAttempts: 2, initialBackoffMs: 10 }
    }
  ];

  await expect(runner.run('saga-comp', steps, {})).rejects.toThrow();

  const state = await db.sagaState.findUnique({ where: { sagaId: 'saga-comp' }});
  expect(state?.status).toBe('COMPENSATED');
  expect(compensateA).toHaveBeenCalled();
});
```

### 5.4 영구 실패 (재시도 X)

```typescript
test('NonRetryableError 즉시 보상', async () => {
  const steps = [
    { name: 'a', execute: async () => ({ a: 1 }), compensate: vi.fn() },
    {
      name: 'b',
      execute: async () => { throw new InsufficientPermissionError(); },
      retryPolicy: {
        maxAttempts: 5,
        isRetryable: (e) => !(e instanceof InsufficientPermissionError)
      }
    }
  ];

  await expect(runner.run('saga-perm', steps, {})).rejects.toThrow();

  // attempt 1 만 (재시도 X) → 즉시 보상
  // assertions on logs / state
});
```

## 6. 통합 가이드

### 6.1 룰 갱신

`.claude/rules/integration.md` § 1.5 (Saga) 보강:

```
## 1.5 Saga (분산 트랜잭션) — v0.3+

step 단위 재시도 / backoff / 보상 트랜잭션 정책:
- transient error: 지수 backoff 재시도 (기본 maxAttempts=3)
- permanent error: 즉시 보상
- 보상 자체 실패: 운영자 알림 + saga 수동 처리

상세: `.claude/boilerplate/03_saga_retry_backoff.md`
```

### 6.2 메트릭

```
saga_step_executed_count{saga_type, step_name, status}
saga_step_retry_count{saga_type, step_name}
saga_compensated_count{saga_type}
saga_compensation_failed_count{saga_type, step_name}  -- critical 알림
```

## 7. 검증 체크리스트

- [ ] 재시도 / backoff 단위 테스트
- [ ] 보상 트랜잭션 단위 테스트
- [ ] transient vs permanent 분류 검증
- [ ] saga 상태 ledger (DbSagaLogger) 정합
- [ ] 메트릭 노출
- [ ] 운영 CLI (`erp-cli saga *`) — 갭 04 / 갭 07
- [ ] `rules/integration.md` § 1.5 갱신

## 8. 참조

- 의존: 갭 01 (idempotency), 갭 02 (outbox)
- 보강: 갭 04 (saga resume — 재시작 후 복구)
- 룰: `.claude/rules/integration.md` § 1.5
