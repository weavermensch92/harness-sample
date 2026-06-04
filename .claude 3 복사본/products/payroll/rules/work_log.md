# 작업 시간 (WorkLog)

> **ID 범위**: EP-100 ~ EP-199
> **주제**: WorkLog 모델 / 외부 이벤트 멱등 / 상태 전이 / 집계 잠금
> **상위**: `INDEX.md`
> **boilerplate 정합**: `business/payroll/handlers/delivery-completed-handler.ts`, `business/payroll/jobs/aggregate-monthly.ts`, `prisma WorkLog` 모델

---

## TL;DR

- **WorkLog = 인건비가 발생한 단일 사실**. 출처는 `attendance` 환산, `delivery` 이벤트, `manual` 입력 등 다양.
- **멱등 2중**: `processed_events.event_id` (핸들러 레벨) + `work_logs(source_type, source_id)` UNIQUE (DB 레벨). 외부 이벤트 핸들러는 재시도 안전.
- **상태 3단**: `ACTIVE` → `CANCELLED` (취소) / `AGGREGATED` (월 마감). 전이는 단방향.
- **AGGREGATED 후 수정 금지** (MUST). 정정은 새 row (조정 트랜잭션) 로만.
- **`amount` 는 즉시 확정 금액**. 시급 × 시간 같은 계산은 발행자(이벤트 페이로드)에서 미리 끝나 있어야 함.
- **트랜잭션 단위 = 사용자 1명**. 월별 배치도 사용자당 1 트랜잭션 (대량 데이터 부분 실패 격리).

핵심 ID: EP-100 (모델) / EP-110 (멱등) / EP-130 (상태 전이) / EP-140 (조정)

---

## 1. WorkLog 모델 (EP-100 ~ EP-109)

### EP-100. 핵심 스키마 (MUST, boilerplate 정합)

```sql
CREATE TABLE work_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  facility_id     UUID NOT NULL,
  team_id         UUID NOT NULL,
  user_id         UUID NOT NULL,                    -- 수당 받을 사람
  source_type     work_log_source NOT NULL,         -- DELIVERY / MANUAL / ATTENDANCE / ADJUSTMENT
  source_id       VARCHAR(100) NOT NULL,            -- 자연 키
  amount          NUMERIC(12, 0) NOT NULL,          -- KRW 정수
  date            DATE NOT NULL,                    -- 발생일 (조직 timezone)
  status          work_log_status NOT NULL DEFAULT 'ACTIVE',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  UNIQUE (source_type, source_id),                  -- 멱등성 (E-820)
  CHECK (amount >= 0)
);

CREATE INDEX idx_work_logs_user_date ON work_logs(user_id, date);
CREATE INDEX idx_work_logs_facility_date ON work_logs(facility_id, date);
CREATE INDEX idx_work_logs_team_date ON work_logs(team_id, date);
CREATE INDEX idx_work_logs_status ON work_logs(status);
```

### EP-101. source_type 매핑

| source_type | 출처 | source_id 의미 | 발행자 |
|---|---|---|---|
| `DELIVERY` | Logistics `DELIVERY_COMPLETED` 이벤트 | deliveryId (logistics_deliveries.id, UUID) | `business/payroll/handlers/delivery-completed-handler.ts` |
| `MANUAL` | L3+ 가 직접 입력 | 자체 UUID | UI / API |
| `ATTENDANCE` | 근태 → 일급/시급 환산 | `att:{user_id}:{date}` | 일배치 잡 (Phase 1+) |
| `ADJUSTMENT` | 마감 후 정정 | `adj:{original_work_log_id}:{seq}` | 조정 트랜잭션 (EP-140) |
| `PIECEWORK` | task_definitions 기반 산출 (v0.11) | `pw:{task_code}:{external_ref}` | piecework 핸들러 (EP-810) |

> **v0.2**: `DELIVERY` 는 `work_log_source` ENUM 에 안전 추가 (`IF NOT EXISTS`). 이미 있을 가능성 높지만 마이그레이션 003 으로 보장.

새 source_type 추가는 enum 마이그레이션 + 해당 발행자 명시 필요.

### EP-102. amount 는 즉시 확정 (MUST)

WorkLog 생성 시점에 `amount` 는 **이미 KRW 정수 확정값**. 시급 × 시간 같은 계산은 호출자(이벤트 발행자) 책임.

```typescript
// ❌ 금지 — WorkLog 안에서 시급 곱셈
await createWorkLog({
  userId, hourlyRate: user.rate, hours: 8
});

// ✅ 정답 — 호출자가 미리 곱해서 amount 만 전달
await createWorkLog({
  userId, sourceType: 'DELIVERY', sourceId: deliveryId,
  amount: 35000,  // 이미 확정
  date: '2026-04-28'
});
```

이유: WorkLog 는 "사실 기록", 계산 변경(시급 인상 소급 등) 시 새 ADJUSTMENT row 로 처리.

---

## 2. 멱등성 (EP-110 ~ EP-119) — 핵심 MUST

### EP-110. 외부 이벤트 핸들러 멱등 2중 (MUST)

외부 이벤트(`DELIVERY_COMPLETED` 등)로 WorkLog 를 생성하는 핸들러는 **반드시 다음 패턴**:

```typescript
// boilerplate: business/payroll/handlers/delivery-completed-handler.ts
await db.$transaction(async (tx) => {
  // 1. ProcessedEvent 체크 — 같은 eventId 재시도 방지
  const already = await tx.processedEvent.findUnique({
    where: { eventId: event.eventId },
  });
  if (already) return;  // 조용히 skip

  // 2. WorkLog upsert — DB UNIQUE 로 race condition 까지 방어
  const { workLog, created } = await workLogRepo.upsertWorkLog({
    sourceType: 'DELIVERY',
    sourceId: event.payload.deliveryId,
    // ... 나머지 필드
  }, tx);

  // 3. ProcessedEvent 기록 — 같은 트랜잭션 안에서
  await tx.processedEvent.create({
    data: { eventId: event.eventId, handler: 'payroll.delivery', ... }
  });

  // 4. 감사 로그
  await writeAudit({ ... }, tx);
});
```

- **1+3 같은 트랜잭션 안**: ProcessedEvent INSERT 가 트랜잭션 일부. 핸들러 실패 시 자동 롤백 → 다음 재시도가 정상 처리.
- **2 의 UNIQUE 제약**: 동일 핸들러가 동시 실행되어도 race condition 차단.

### EP-111. ProcessedEvent 기록 형식

```sql
CREATE TABLE processed_events (
  event_id     VARCHAR(100) PRIMARY KEY,    -- 이벤트의 자연 ID
  handler      VARCHAR(100) NOT NULL,       -- 'payroll.delivery' 등
  processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata     JSONB
);
CREATE INDEX idx_processed_events_handler ON processed_events(handler, processed_at);
```

같은 이벤트가 여러 핸들러에서 처리될 수 있으나, **(eventId) 가 PK** 라서 같은 이벤트는 첫 핸들러에서만 처리됨.
→ 다른 핸들러도 같은 이벤트를 처리해야 한다면 `(eventId, handler)` 복합 PK 로 마이그레이션 필요.

### EP-115. 사용자 손 입력 멱등 (SHOULD)

`MANUAL` source 는 자연 키가 없으므로 멱등성을 **API 클라이언트 측 idempotency key** 로 보장:

```
POST /api/work-logs
Idempotency-Key: ui-2026-04-28-manual-3f8a...
```

서버는 이 키를 `(source_type='MANUAL', source_id=key)` 로 저장. 같은 키 재요청은 기존 row 반환.

---

## 3. 상태 전이 (EP-120 ~ EP-139)

### EP-120. 상태 머신 (MUST)

```
       create
         │
         ▼
   ┌─────────────┐
   │   ACTIVE    │
   └──┬────┬─────┘
      │    │
   cancel  monthly_aggregate
      │    │
      ▼    ▼
  CANCELLED   AGGREGATED   ← 종착, 수정 불가
```

**불가능한 전이:**
- `CANCELLED → ACTIVE` (취소 후 부활)
- `AGGREGATED → ACTIVE` (마감 후 활성화)
- `AGGREGATED → CANCELLED` (마감 후 취소)
- `CANCELLED → AGGREGATED` (집계는 ACTIVE 만 대상)

위반 시도는 도메인 에러:

```typescript
if (workLog.status !== 'ACTIVE') {
  throw new InvalidStateTransitionError(
    `WorkLog ${workLog.id} 는 ${workLog.status} 상태라 변경 불가`
  );
}
```

### EP-130. 월별 집계 (MUST, boilerplate 정합)

`business/payroll/jobs/aggregate-monthly.ts` 동작:

```
입력: month "YYYY-MM" + dryRun
1. 해당 월의 ACTIVE WorkLog 를 (user_id, facility_id, team_id) 별로 그룹핑
2. 사용자별 1 트랜잭션:
   - 해당 사용자의 ACTIVE → AGGREGATED 일괄 UPDATE
   - 감사 로그 (action='payroll.aggregate_monthly')
3. 부분 실패 시 해당 사용자만 롤백, 다음 사용자 계속
```

**왜 사용자당 1 트랜잭션:**
- 5,000명 × 1 트랜잭션 일괄 = 1명 실패 시 전체 롤백 → 운영 부담
- 사용자당 분리 = 부분 실패 격리, 나머지 마감 진행

### EP-131. 멱등 집계 (MUST)

같은 month 로 두 번 실행해도 같은 결과. 두 번째 실행 시 ACTIVE 가 없으므로 `updated.count === 0` (자연 멱등).

### EP-140. 정정 / 조정 (MUST)

AGGREGATED 후 정정은 **원 row 수정 금지, 새 ADJUSTMENT row 생성**:

```typescript
// 04월 김씨 일당 35,000 → 잘못 입력, 33,000 이 맞음 (이미 AGGREGATED)
await db.workLog.create({
  data: {
    userId: '...',
    sourceType: 'ADJUSTMENT',
    sourceId: `adj:${originalWorkLog.id}:1`,
    amount: -2000,                        // 음수로 보정
    date: originalWorkLog.date,
    status: 'ACTIVE',                     // 다음 달 집계 대상
    // ...
  }
});
```

- 보정 row 는 **금액 차이만큼**의 음수/양수
- 다음 달 집계에 자연스럽게 흡수
- 원 row 는 그대로 보존 (감사)

---

## 4. 조회 / 마스킹 (EP-150 ~ EP-169)

### EP-150. amount 마스킹 (MUST)

WorkLog 의 `amount` 는 급여액. 응답 직전에 `maskField()` 경유:

```typescript
const dto = workLogs.map(w => ({
  ...w,
  amount: maskField(w.amount, 'salary', currentUser, { owner_id: w.user_id })
}));
```

- L1 본인: 원본 / L1 타인: `'***'`
- L2: 항상 `'***'` (팀원 급여 열람 불가)
- L3+ 팀원: 원본
- L4: 원본
- Super: 기본 마스킹, 해제 시 audit

### EP-160. 페이징 / 인덱스 (MUST)

대량 조회는 항상:
- `(user_id, date DESC)` 인덱스 활용 (개인별)
- `(facility_id, date)` 인덱스 활용 (관리자 대시보드)
- LIMIT 필수 (max 1000)

```typescript
// ✅ 정답
await db.workLog.findMany({
  where: { userId, date: { gte: from, lte: to } },
  orderBy: [{ date: 'desc' }],
  take: limit,
  cursor,
});
```

---

## 5. 외부 발행 (EP-170 ~ EP-179)

### EP-170. WorkLog 이벤트 (Outbox 패턴)

WorkLog 생성/취소/집계 시 외부 이벤트 발행:

| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `payroll.work_log.created` | INSERT 직후 | userId / sourceType / sourceId / amount / date |
| `payroll.work_log.cancelled` | ACTIVE → CANCELLED | userId / sourceType / sourceId / reason |
| `payroll.records.aggregated` | 월별 집계 완료 | userIds[] / month / totalAmount |

발행은 **Outbox 패턴** (E-830). 직접 publish 금지.

```typescript
await db.$transaction(async (tx) => {
  await tx.workLog.create({ ... });
  await tx.eventOutbox.create({
    data: {
      aggregateId: workLog.id,
      aggregateType: 'work_log',
      eventType: 'payroll.work_log.created',
      payload: { ... },
    }
  });
});
// outbox publisher worker 가 별도로 published=true 마킹하며 발행
```

> ⚠️ **현재 v0.9.0 갭**: `event_outbox` 테이블은 있으나 폴링 워커는 미구현. v1.0 에서 보강 예정.

---

## 6. 권한 (EP-180 ~ EP-189)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 WorkLog 조회 | ✅ (마스킹 해제) | ✅ | ✅ | ✅ | ⚠️ |
| 팀원 WorkLog 조회 (마스킹) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 팀원 WorkLog 조회 (금액) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| MANUAL WorkLog 생성 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| WorkLog 취소 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 월말 집계 실행 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| ADJUSTMENT 생성 | ❌ | ❌ | ❌ | ✅ | ⚠️ |

---

## 7. 감사 (EP-190 ~ EP-199)

### EP-190. 필수 audit 액션

| action | 시점 |
|---|---|
| `payroll.work_log.created` | 생성 |
| `payroll.work_log.created_from_delivery` | DELIVERY 이벤트로 생성 (시스템 액터) |
| `payroll.work_log.cancelled_from_delivery` | DELIVERY 취소로 cancel |
| `payroll.work_log.cancel_requires_adjustment` | AGGREGATED 인데 취소 시도 (운영자 개입) |
| `payroll.aggregate_monthly` | 월별 집계 (사용자별) |
| `payroll.work_log.adjusted` | ADJUSTMENT row 생성 |
| `payroll.work_log.amount_unmasked` | Super 가 마스킹 해제 조회 |

`metadata` 에 before / after / reason 필수.

---

## 8. 참조

- 권한 / 마스킹: `../../../rules/permissions.md` § E-420
- 이벤트 / Outbox: `../../../rules/integration.md` § E-830
- 코드: `business/payroll/handlers/delivery-completed-handler.ts`, `business/payroll/jobs/aggregate-monthly.ts`
- 다음 단계: 급여 계산 → `salary_calc.md`
- 스키마: `../schemas/tables/payroll_work_logs.sql`
