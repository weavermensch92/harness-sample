# 지급 (Payment)

> **ID 범위**: EP-500 ~ EP-599
> **주제**: 급여 지급 사이클 / 은행 이체 / 보류 / 환수
> **상위**: `INDEX.md`
> **기준법**: 근로기준법 §43 (임금 직접지급 / 정기지급 원칙)

---

## TL;DR

- **지급 = `payroll_records.status = PAID` 전이 + `payroll_payments` row INSERT**. 두 테이블 정합 (트랜잭션 강제).
- **법적 원칙 4종 (KR, MUST)**: ① 통화 ② 직접 ③ 전액 ④ 매월 1회 정기. 위반 = 임금체불 (3년 이하 징역 / 3천만원 이하 벌금).
- **이체는 외부 게이트웨이 호출** — Saga 패턴. 호출 전/후 상태 기록, 실패 시 보상 (PAID → FINALIZED 롤백).
- **멱등성** — `payroll_payments(record_id, attempt)` UNIQUE. 재시도는 새 attempt row, 이중 이체 차단.
- **환수 (Clawback)** — 지급 후 정정 / 과지급은 별도 트랜잭션. 본인 동의 / 차감 한도 (월급의 1/4 이하, KR §43) 준수.
- **권한**: 승인 = L4 only. Super 도 직접 지급 불가 (감사 격리).

핵심 ID: EP-510 (4원칙) / EP-520 (Saga) / EP-530 (멱등) / EP-560 (환수)

---

## 1. 법적 원칙 (EP-500 ~ EP-509) — MUST, KR

### EP-500. 임금 4대 원칙 (MUST)

근로기준법 §43:

1. **통화 지급** — 통용 화폐 (KRW). 현물 / 어음 / 상품권 금지. 외화는 근로계약 명시 + 동의 시만.
2. **직접 지급** — 본인 명의 계좌 / 본인 수령. 가족 계좌 송금 금지 (예외: 위임장 등).
3. **전액 지급** — 임의 공제 금지. 공제는 법령 / 단체협약 / 취업규칙 근거 필요.
4. **매월 1회 이상 정기 지급** — 지급일 변동 시 사전 합의 + 근로자 동의.

### EP-501. 위반 결과

- 임금체불 (지급일 미준수 / 미지급) → 신고 시 노동청 조사
- 형사처벌 (§109): 3년 이하 징역 또는 3천만원 이하 벌금

### EP-502. 시스템적 강제

| 원칙 | 시스템 강제 가능? | 강제 방법 |
|---|---|---|
| 통화 | ✅ | `currency = KRW` 고정 검증 |
| 직접 | ⚠️ 부분 | 본인 명의 계좌 검증 (예금주명 확인) |
| 전액 | ✅ | 임의 공제 동의 문서 필드 (EP-389) |
| 정기 | ✅ | 지급 사이클 강제 + 미지급 알림 |

---

## 2. 지급 사이클 (EP-510 ~ EP-519)

### EP-510. 사업장 지급일 (MUST)

조직별 지급일 정책:

```sql
ALTER TABLE organizations ADD COLUMN payday_pattern VARCHAR(50);
-- 'last_day' / 'specific_day:25' / 'next_month:5' 등
```

자주 쓰이는 패턴:
- 월말 (말일 / 영업일 보정)
- 매월 25일 / 익월 5일 / 익월 10일

### EP-510-A. 사용자별 payment_cycle (MUST, v0.11)

`payroll_compensation_settings.payment_cycle` 로 사용자 단위 사이클 지정:

| 값 | 의미 | 주 사용처 |
|---|---|---|
| `MONTHLY` | 월 1회 (조직 payday_pattern 따름) | 정규직 기본 |
| `WEEKLY` | 주 1회 | 일용직 누적, 단기 알바 |
| `DAILY` | 당일 / 익일 | 일용직, 일급제 |
| `IMMEDIATE` | 작업 완료 즉시 | 배송 기사, 도급 |

일용직 / piecework 도입 시 사이클 다양화. 자세한 처리는 `day_laborer.md` § EP-740 ~ EP-755.

게이트:
- `IMMEDIATE` / `DAILY` 사이클은 `payroll.day_laborer` 토글 ON 인 경우만 활성화 권장 (정규직 일별 지급은 위험)

### EP-511. 영업일 보정 (MUST)

지급일이 토 / 일 / 공휴일이면 **직전 영업일** 로 자동 앞당김 (KR 관행).

```typescript
function adjustToBusinessDay(date: Date, calendar: Holiday[]): Date {
  while (isWeekend(date) || calendar.includes(date)) {
    date = subDays(date, 1);
  }
  return date;
}
```

### EP-515. 지급 트리거

- 자동: cron 으로 지급일 도래 시 FINALIZED 상태인 record 일괄 처리
- 수동: L4 가 대시보드에서 일괄 승인 (Phase 1+ 권장)

자동 vs 수동은 조직 설정 (`organizations.payment_trigger_mode`).

---

## 3. 지급 트랜잭션 (EP-520 ~ EP-539) — MUST

### EP-520. Saga 패턴 (MUST)

지급은 외부 시스템 (은행 게이트웨이 / 회계) 과 엮인 분산 트랜잭션 → **Saga**:

```
Step 1. record FINALIZED → PAYMENT_INITIATED 전이 + payment row INSERT (DB)
        ↓ compensate: PAYMENT_INITIATED → FINALIZED 복구
Step 2. 은행 이체 API 호출
        ↓ compensate: 취소 API 호출 (가능한 경우만, 한국 은행 즉시 취소 어려움)
Step 3. 이체 성공 → record PAID 전이 + payment.status='SUCCESS'
        ↓ compensate 없음 (성공 후 보상은 환수 트랜잭션 EP-560)
Step 4. payslip 발급 트리거 + 알림
        ↓ compensate 없음 (보상 불필요)
```

`business/shared/saga/` 의 SagaOrchestrator 사용. sagaType = 'PAYROLL_PAYMENT'.

### EP-521. Step 2 의 risk (MUST)

은행 이체 API 호출은 **돌이킬 수 없을 수 있음** — 한국은 즉시 출금 후 취소 거의 불가. 따라서:

- Step 2 호출 직전: payment 상태 = `INITIATED` (이체 시도 중)
- Step 2 호출 결과:
  - 성공 → Step 3 진행
  - 실패 (네트워크 / 4xx 응답) → Step 1 보상 (record 롤백)
  - 타임아웃 → **불확정** (`PENDING_VERIFICATION`) 상태 + 운영자 알림 + 자동 재시도 금지

### EP-525. payment 모델 (MUST)

```sql
CREATE TABLE payroll_payments (
  id              UUID PRIMARY KEY,
  record_id       UUID NOT NULL,
  user_id         UUID NOT NULL,
  attempt         INTEGER NOT NULL DEFAULT 1,
  amount          NUMERIC(12, 0) NOT NULL,
  bank_code       VARCHAR(10) NOT NULL,
  account_number  VARCHAR(50) NOT NULL,            -- 마스킹 표시용 별도 컬럼 가능
  account_holder  VARCHAR(100) NOT NULL,           -- 본인 명의 검증
  status          payment_status NOT NULL DEFAULT 'INITIATED',
  bank_ref        VARCHAR(100),                    -- 은행 트랜잭션 참조 ID
  initiated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ,
  failed_reason   TEXT,
  created_by      UUID NOT NULL,                   -- 승인자
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (record_id, attempt)
);

CREATE TYPE payment_status AS ENUM (
  'INITIATED',             -- 이체 시도 중
  'SUCCESS',               -- 이체 완료
  'FAILED',                -- 명확한 실패 (보상 가능)
  'PENDING_VERIFICATION',  -- 불확정 (수동 확인 필요)
  'CANCELLED'              -- 사전 취소
);
```

### EP-530. 멱등 / 재시도 (MUST)

- 같은 record 에 대해 INITIATED / PENDING_VERIFICATION 이 있으면 새 시도 차단.
- 재시도는 명시적 운영자 액션으로 새 `attempt` 번호.
- `(record_id, attempt)` UNIQUE 로 동시 시도 race 차단.

```typescript
async function startPayment(recordId: string, actor: User) {
  await db.$transaction(async (tx) => {
    const existing = await tx.payrollPayment.findFirst({
      where: { recordId, status: { in: ['INITIATED', 'PENDING_VERIFICATION', 'SUCCESS'] }}
    });
    if (existing) throw new DuplicatePaymentError(`기존 attempt #${existing.attempt} 존재`);

    const last = await tx.payrollPayment.findFirst({
      where: { recordId },
      orderBy: { attempt: 'desc' }
    });
    const newAttempt = (last?.attempt ?? 0) + 1;

    await tx.payrollPayment.create({
      data: { recordId, attempt: newAttempt, status: 'INITIATED', ...}
    });
  });
  // 트랜잭션 외부에서 은행 호출
}
```

### EP-535. 본인 명의 검증 (MUST)

이체 직전에 `account_holder` 와 `user.name` 일치 검증. 불일치 시 거부 + audit:

```typescript
if (normalize(payment.accountHolder) !== normalize(user.name)) {
  throw new AccountHolderMismatchError(
    `예금주(${payment.accountHolder}) ≠ 사용자(${user.name})`
  );
}
```

> 회사 명의 / 가족 명의 송금은 §43 ② 직접 지급 위반. 시스템 차원에서 차단.

---

## 4. 외부 게이트웨이 (EP-540 ~ EP-549)

### EP-540. 어댑터 인터페이스 (MUST)

은행 이체는 어댑터 패턴:

```typescript
interface BankTransferAdapter {
  transfer(req: TransferRequest): Promise<TransferResult>;
  status(bankRef: string): Promise<TransferStatus>;
  cancel?(bankRef: string): Promise<CancelResult>;  // 가능한 경우만
}

// 구현체:
// - MockBankAdapter (개발 / 테스트)
// - FirmBankingAdapter (KR 펌뱅킹 — 농협 / 우리 / 국민 등)
// - OpenBankingAdapter (KR 오픈뱅킹)
// - StripeAdapter (해외 — Phase 2+)
```

### EP-541. 환경 변수로 분기 (MUST)

```typescript
const provider = process.env.BANK_PROVIDER ?? 'mock';
// 'mock' / 'firmbanking' / 'openbanking' / 'stripe'
```

local / dev = `mock` 강제. 운영 = 사업장별 설정.

### EP-545. 타임아웃 / 재시도 (MUST)

- 호출 timeout: 30초 (은행 API 평균 5~15초)
- 자동 재시도 **금지**: 같은 요청을 두 번 호출해서 이중 출금 위험. 타임아웃 시 `status()` 폴링.
- 운영자가 수동으로 새 attempt 만 가능.

### EP-546. 일괄 이체 (Phase 2+)

대량 사업장은 일괄 이체 (Bulk Transfer) 권장. 각 row 결과는 비동기 webhook 으로 수신. `payroll_payments` 가 그대로 소비자.

---

## 5. 환수 / 정정 (EP-560 ~ EP-579)

### EP-560. 과지급 환수 (MUST)

이미 PAID 된 record 에 정정 사유 발생 (계산 오류 / 결근 누락 등) → 환수:

옵션 A — 차감 (권장):
```
다음 달 record 에 ADJUSTMENT row (음수) 추가 → 자연 차감
한도: 월급의 1/4 이하 (KR §43, MUST)
```

옵션 B — 직접 환수:
```
근로자 동의 + 환수 합의서 → 별도 환수 트랜잭션
```

### EP-561. 차감 한도 (MUST, KR)

근로기준법 §43 ② — 임금의 1/4 초과 공제 금지. 환수 차감도 동일.

```typescript
const maxDeduction = Math.floor(record.netPayment / 4);
if (clawback.amount > maxDeduction) {
  throw new ClawbackExceedsLimitError(
    `환수액 ${clawback.amount} > 월급의 1/4 (${maxDeduction})`
  );
}
```

여러 달 분할 차감 가능. `clawback_schedule` 테이블 (Phase 2+).

### EP-565. 미지급 환수

이체 실패 → 자동 환수 (record FINALIZED 로 롤백). 다음 사이클에 재시도.

`status='FAILED'` 인 payment 의 보상 (Saga Step 1 의 compensate) 에서 자동 처리.

### EP-570. PENDING_VERIFICATION 처리 (MUST)

이체 결과 불확정 (타임아웃 등) → 운영자가 직접 은행 시스템에서 확인 후:
- 이체된 것으로 확인 → `status='SUCCESS'` + 메모
- 미이체 확인 → `status='FAILED'` + Saga 보상

자동 전이 금지. 운영 대시보드에서 수동.

---

## 6. 발행 이벤트 (EP-580 ~ EP-589)

| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `payroll.payment.initiated` | INITIATED row 생성 | userId / recordId / amount |
| `payroll.payment.issued` | SUCCESS 전이 | userId / month / amount / bankRef |
| `payroll.payment.failed` | FAILED 전이 | userId / month / reason |
| `payroll.payment.pending_verification` | 불확정 | userId / month / reason |
| `payroll.payment.clawback_scheduled` | 환수 차감 예약 | userId / amount / months[] |

Outbox 패턴 (`integration.md` § E-830).

---

## 7. 권한 (EP-590 ~ EP-599)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 지급 이력 조회 | ✅ (마스킹 해제) | ✅ | ✅ | ✅ | ⚠️ |
| 팀 지급 이력 조회 (마스킹) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 팀 지급 이력 (금액) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 지급 승인 | ❌ | ❌ | ❌ | ✅ | **❌** |
| 지급 실행 (배치) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| PENDING_VERIFICATION 해소 | ❌ | ❌ | ❌ | ✅ | ✅ (감사) |
| 환수 시작 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 은행 어댑터 설정 변경 | ❌ | ❌ | ❌ | ❌ | ✅ |

> ⚠️ **Super 는 지급 승인 불가** — 감사 격리. 권한 자체 관리는 Super, 비즈니스 액션은 L4.

---

## 8. 감사 (EP-595 ~ EP-599)

### EP-595. 필수 audit 액션

| action | 시점 |
|---|---|
| `payroll.payment.initiated` | 이체 시도 |
| `payroll.payment.succeeded` | 이체 성공 |
| `payroll.payment.failed` | 이체 실패 |
| `payroll.payment.pending_verification` | 불확정 |
| `payroll.payment.verified_by_operator` | 운영자 수동 확인 |
| `payroll.payment.clawback_started` | 환수 시작 |
| `payroll.payment.account_unmasked` | 계좌번호 마스킹 해제 조회 |

`metadata` 에 amount / bankRef / actor / reason 필수.

---

## 9. 참조

- Saga 패턴: `../../../rules/integration.md` § E-840
- Outbox: `../../../rules/integration.md` § E-830
- 임금 4대 원칙: 근로기준법 §43
- 다음 영역: 은행 어댑터 구현 (EP-600~), Phase 2+
- 스키마: `../schemas/tables/payroll_payments.sql`
