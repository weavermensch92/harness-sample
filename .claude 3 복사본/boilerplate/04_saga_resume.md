# 갭 04 — Saga 자동 Resume

> **버전**: v0.3 진입 시 구현
> **위치**: `@erp-harness/core` saga 모듈 보강
> **영향**: 장애 복구 / 서버 재시작 후 진행 중 saga 자동 재개
> **의존**: 갭 03 (saga retry/backoff)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- `DbSagaLogger` 가 saga state / step 이력 보존
- 서버 재시작 / 크래시 → 진행 중 saga 가 RUNNING 상태로 멈춤
- **자동 재개 메커니즘 부재** — 운영자가 수동 발견 / 재실행 필요

### 영향

- 서버 재시작 시 진행 중 ORDER_CONFIRMED saga 가 멈춤 → 고객 주문 처리 X
- 재시도 대기 중 (`nextRetryAt`) 인 saga 도 자동 깨어나지 않음
- 분산 환경 (multi-instance) 에서 saga 가 "사라짐" — 어떤 인스턴스가 처리할지 불명확

### 목표

서버 시작 시 / 주기적으로 진행 중 saga 를 발견 → 마지막 step 부터 재개. SKIP LOCKED 로 분산 worker 안전.

---

## 1. 인터페이스

```typescript
// business/_shared/saga/resumer.ts

export interface SagaResumerOptions {
  /** 폴링 간격 ms (기본 30s) */
  pollIntervalMs?: number;
  /** 한 번에 가져올 saga 수 (기본 50) */
  batchSize?: number;
  /** 등록된 saga 정의 (sagaType → steps) */
  sagaDefinitions: Map<string, () => SagaStep<any, any>[]>;
  /** stale saga 판정 — N 시간 이상 RUNNING 상태 (기본 1시간) */
  staleThresholdMs?: number;
}

export interface SagaCandidate {
  sagaId: string;
  sagaType: string;          // 'order_confirmed' / 'payroll_payment' 등
  status: 'RUNNING' | 'COMPENSATING';
  currentStep: string | null;
  nextRetryAt?: Date;
  lastUpdatedAt: Date;
}
```

## 2. 핵심 구현

```typescript
// business/_shared/saga/resumer.ts

const DEFAULT_OPTIONS = {
  pollIntervalMs: 30_000,
  batchSize: 50,
  staleThresholdMs: 60 * 60 * 1000,  // 1h
};

export class SagaResumer {
  private isRunning = false;
  private currentLoop: Promise<void> | null = null;

  constructor(
    private readonly db: PrismaClient,
    private readonly runner: SagaRunner,
    private readonly options: SagaResumerOptions
  ) {}

  /** 서버 시작 시 한 번 호출 — 진행 중 saga 즉시 재개 */
  async resumeAllOnStartup(): Promise<number> {
    logger.info('SagaResumer: scanning for in-progress sagas...');
    let resumed = 0;
    while (true) {
      const candidates = await this.findResumableCandidates();
      if (candidates.length === 0) break;

      for (const candidate of candidates) {
        try {
          await this.resumeOne(candidate);
          resumed++;
        } catch (e) {
          logger.error(`SagaResumer: failed to resume ${candidate.sagaId}`, e);
        }
      }
    }
    logger.info(`SagaResumer: resumed ${resumed} sagas`);
    return resumed;
  }

  /** 백그라운드 폴링 시작 */
  start(): void {
    if (this.isRunning) return;
    this.isRunning = true;
    this.currentLoop = this.runLoop();
  }

  async stop(): Promise<void> {
    this.isRunning = false;
    if (this.currentLoop) await this.currentLoop;
  }

  private async runLoop(): Promise<void> {
    while (this.isRunning) {
      try {
        await this.tick();
      } catch (e) {
        logger.error('SagaResumer loop error', e);
      }
      await sleep(this.options.pollIntervalMs ?? DEFAULT_OPTIONS.pollIntervalMs);
    }
  }

  async tick(): Promise<number> {
    const candidates = await this.findResumableCandidates();
    let resumed = 0;
    for (const candidate of candidates) {
      try {
        await this.resumeOne(candidate);
        resumed++;
      } catch (e) {
        logger.error(`SagaResumer tick: ${candidate.sagaId}`, e);
      }
    }
    return resumed;
  }

  private async findResumableCandidates(): Promise<SagaCandidate[]> {
    const now = new Date();
    const staleThreshold = new Date(Date.now() - (this.options.staleThresholdMs ?? DEFAULT_OPTIONS.staleThresholdMs));
    const batchSize = this.options.batchSize ?? DEFAULT_OPTIONS.batchSize;

    // SKIP LOCKED — 분산 worker 안전
    return await this.db.$queryRaw<SagaCandidate[]>`
      SELECT * FROM saga_state
       WHERE status IN ('RUNNING', 'COMPENSATING')
         AND (
           -- 재시도 시각 도달
           (next_retry_at IS NOT NULL AND next_retry_at <= ${now})
           OR
           -- stale — 마지막 갱신 너무 오래
           (next_retry_at IS NULL AND last_updated_at < ${staleThreshold})
         )
       ORDER BY last_updated_at ASC
       LIMIT ${batchSize}
       FOR UPDATE SKIP LOCKED;
    `;
  }

  private async resumeOne(candidate: SagaCandidate): Promise<void> {
    const definition = this.options.sagaDefinitions.get(candidate.sagaType);
    if (!definition) {
      logger.error(`SagaResumer: unknown saga type ${candidate.sagaType} for ${candidate.sagaId}`);
      // 알 수 없는 saga 타입 — 운영자 알림
      await alertOps(`Unknown saga type: ${candidate.sagaType}`);
      return;
    }

    const steps = definition();
    logger.info(`SagaResumer: resuming ${candidate.sagaId} (type=${candidate.sagaType}, step=${candidate.currentStep})`);

    // SagaRunner 가 currentStep 부터 재개 (이미 갭 03 에서 구현)
    try {
      await this.runner.run(candidate.sagaId, steps, {});
      metrics.saga_resumed_count.inc({ saga_type: candidate.sagaType, status: 'success' });
    } catch (e) {
      metrics.saga_resumed_count.inc({ saga_type: candidate.sagaType, status: 'failed' });
      throw e;
    }
  }
}
```

## 3. Saga 등록 (서버 부트스트랩)

```typescript
// app/server.ts

import { SagaResumer, SagaRunner } from '@erp-shared/saga';
import { orderConfirmedSaga } from '@erp/logistics/sagas/order-confirmed-saga';
import { payrollPaymentSaga } from '@erp/payroll/sagas/payment-saga';

const runner = new SagaRunner(db, new DbSagaLogger());

const resumer = new SagaResumer(db, runner, {
  sagaDefinitions: new Map([
    ['order_confirmed', () => orderConfirmedSaga.steps],
    ['payroll_payment', () => payrollPaymentSaga.steps],
    ['return_received', () => returnReceivedSaga.steps]
  ])
});

// 서버 시작 시 즉시 진행 중 saga 재개
await resumer.resumeAllOnStartup();

// 백그라운드 폴링 시작
resumer.start();

// graceful shutdown
process.on('SIGTERM', async () => {
  await resumer.stop();
  await db.$disconnect();
});
```

## 4. saga_state 스키마 (보강)

```sql
-- 기존 스키마 (v0.9.0) 에 추가 필드
ALTER TABLE saga_state
  ADD COLUMN IF NOT EXISTS saga_type VARCHAR(80) NOT NULL DEFAULT 'unknown',
  ADD COLUMN IF NOT EXISTS last_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- next_retry_at 인덱스 (resumer 폴링 성능)
CREATE INDEX IF NOT EXISTS idx_saga_state_resumable
  ON saga_state (next_retry_at, last_updated_at)
  WHERE status IN ('RUNNING', 'COMPENSATING');
```

## 5. saga_type 등록 정책

각 saga 정의에 `saga_type` 명시:

```typescript
// business/logistics/sagas/order-confirmed-saga.ts

export const orderConfirmedSaga = {
  type: 'order_confirmed',
  steps: [/* ... */] as SagaStep<any, any>[]
};

// 시작 시
await runner.run(
  `saga:order:${orderId}`,
  orderConfirmedSaga.steps,
  initialInput,
  { sagaType: 'order_confirmed' }   // SagaRunner.run 시그니처에 추가
);
```

`SagaRunner` 의 `run()` 시그니처 보강 (갭 03 추가):

```typescript
run<T>(
  sagaId: string,
  steps: SagaStep<any, any>[],
  initialInput: T,
  options: { sagaType: string }   // 추가
): Promise<unknown>
```

## 6. 테스트 시나리오

### 6.1 RUNNING saga 자동 재개

```typescript
test('서버 재시작 후 RUNNING saga 재개', async () => {
  // 미리 RUNNING 상태 saga 시드
  await db.sagaState.create({
    data: {
      sagaId: 'saga-stale',
      sagaType: 'test_saga',
      status: 'RUNNING',
      currentStep: 'step_b',
      attemptCount: 0,
      lastUpdatedAt: new Date(Date.now() - 2 * 60 * 60 * 1000)  // 2h 전
    }
  });

  let stepBExecuted = false;
  const testSaga = () => [
    { name: 'step_a', execute: async () => ({ a: 1 }) },
    { name: 'step_b', execute: async () => { stepBExecuted = true; return { b: 2 }; }}
  ];

  const resumer = new SagaResumer(db, runner, {
    sagaDefinitions: new Map([['test_saga', testSaga]]),
    staleThresholdMs: 60 * 60 * 1000  // 1h
  });

  await resumer.resumeAllOnStartup();

  expect(stepBExecuted).toBe(true);
  const state = await db.sagaState.findUnique({ where: { sagaId: 'saga-stale' }});
  expect(state?.status).toBe('COMPLETED');
});
```

### 6.2 nextRetryAt 도달 saga 자동 재개

```typescript
test('재시도 대기 saga 자동 깨우기', async () => {
  await db.sagaState.create({
    data: {
      sagaId: 'saga-pending-retry',
      sagaType: 'test_saga',
      status: 'RUNNING',
      currentStep: 'step_a',
      attemptCount: 1,
      nextRetryAt: new Date(Date.now() - 1000),   // 1s 전 도달
      lastUpdatedAt: new Date()
    }
  });

  await resumer.tick();

  // step_a 재실행됨
});
```

### 6.3 분산 worker race condition

```typescript
test('동시 resumer 가 같은 saga 처리 X', async () => {
  // 100 stale saga
  for (let i = 0; i < 100; i++) {
    await db.sagaState.create({ /* ... */ });
  }

  const r1 = new SagaResumer(db, runner1, opts);
  const r2 = new SagaResumer(db, runner2, opts);

  await Promise.all([r1.tick(), r2.tick()]);

  // 정확히 100 saga 만 처리
});
```

### 6.4 알 수 없는 saga type

```typescript
test('등록 안 된 saga type → 운영자 알림', async () => {
  await db.sagaState.create({
    data: { sagaId: 's-unknown', sagaType: 'unknown_saga', status: 'RUNNING', /* ... */ }
  });

  const alertSpy = vi.spyOn(opsAlerter, 'alert');
  const resumer = new SagaResumer(db, runner, { sagaDefinitions: new Map() });

  await resumer.resumeAllOnStartup();

  expect(alertSpy).toHaveBeenCalledWith(expect.stringContaining('Unknown saga type'));
});
```

## 7. 운영 / 관측

### 7.1 메트릭

```
saga_resumed_count{saga_type, status}     -- success / failed
saga_running_gauge{saga_type}              -- 현재 RUNNING 인 saga 수
saga_stale_count{saga_type}                -- stale 임계 초과 saga 수 (alert)
```

### 7.2 운영 CLI (갭 07)

```bash
# 진행 중 saga 목록
erp-cli saga list --status RUNNING

# 특정 saga 상태 조회
erp-cli saga show <saga-id>

# 수동 재개
erp-cli saga resume <saga-id>

# 강제 보상 트랜잭션
erp-cli saga compensate <saga-id> --reason "..."

# stale saga 알림
erp-cli saga stale --older 24h
```

### 7.3 알림 임계

| 메트릭 | 임계 | 알림 |
|---|---|---|
| `saga_running_gauge` > 1000 | 5분 | warn |
| `saga_stale_count` > 0 (1h+) | 즉시 | warn |
| `saga_stale_count` > 10 | 즉시 | critical |
| 같은 sagaId 가 24h 이상 RUNNING | 즉시 | critical (수동 개입) |

## 8. 통합 가이드

### 8.1 룰 갱신

`.claude/rules/integration.md` § 1.5 (Saga) 추가:

```
## 1.5 Saga (분산 트랜잭션) — v0.3+

(갭 03 retry/backoff 와 결합)

자동 resume:
- 서버 시작 시 즉시 진행 중 saga 재개 (`resumeAllOnStartup()`)
- 백그라운드 polling — nextRetryAt 도달 / stale (1h+) saga 발견 → 재개
- SKIP LOCKED 로 분산 worker 안전
- 알 수 없는 saga_type → 운영자 알림 + saga 보존

상세: `.claude/boilerplate/04_saga_resume.md`
```

### 8.2 부트스트랩 체크리스트

- [ ] 모든 saga 정의에 `saga_type` 부여
- [ ] 서버 부팅 시 SagaResumer 등록 + `resumeAllOnStartup()` 호출
- [ ] graceful shutdown 에 `resumer.stop()` 포함
- [ ] saga_state 에 `saga_type` / `last_updated_at` 컬럼 마이그레이션

## 9. 검증 체크리스트

- [ ] resumeAllOnStartup() 단위 테스트
- [ ] tick() 폴링 단위 테스트
- [ ] SKIP LOCKED 분산 worker 안전
- [ ] stale saga 발견 / 알림
- [ ] saga_type 등록 / 알 수 없는 타입 처리
- [ ] 운영 CLI 통합 (`erp-cli saga *`)
- [ ] `rules/integration.md` § 1.5 갱신

## 10. 참조

- 의존: 갭 03 (saga retry/backoff)
- 보강: 갭 07 (CLI)
- 룰: `.claude/rules/integration.md` § 1.5
