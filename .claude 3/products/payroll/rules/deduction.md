# 공제 (Deduction)

> **ID 범위**: EP-350 ~ EP-399
> **주제**: 4대보험 / 소득세 / 지방소득세 / 사내 공제
> **상위**: `INDEX.md`
> **기준법**: 국민연금법 / 국민건강보험법 / 고용보험법 / 산업재해보상보험법 / 소득세법

---

## TL;DR

- **법정 공제 = 4대보험 + 소득세 + 지방소득세**. 임의 공제 = 사내 대출 / 노조비 / 기타.
- **요율은 매년 변경 (MUST)** — 별도 `deduction_rates` 테이블에 연도별 보관. 코드 하드코딩 금지.
- **소득세는 간이세액표 기반 추정**. 확정은 연말정산. 월별 record 의 소득세는 **간이세액 (예측치)** 임을 명시.
- **산재보험은 100% 사업주 부담** — 근로자 공제 대상 아님. 회계 처리만.
- **공제 항목별 row**: `payroll_deductions`. record 와 1:N. 명세서에서 항목별 표시.
- **공제 합계 검증** (MUST): `record.total_deduction = SUM(deductions.amount)` 일치 보장. 불일치 시 INSERT 거부.

핵심 ID: EP-360 (요율 테이블) / EP-370 (4대보험 산식) / EP-380 (소득세 간이세액) / EP-390 (검증)

---

## 1. 공제 분류 (EP-350 ~ EP-359)

### EP-350. 카탈로그

```sql
CREATE TYPE deduction_type AS ENUM (
  -- 법정 (4대보험)
  'NATIONAL_PENSION',     -- 국민연금
  'HEALTH_INSURANCE',     -- 건강보험
  'LONG_TERM_CARE',       -- 장기요양보험 (건강보험 부속)
  'EMPLOYMENT_INSURANCE', -- 고용보험
  -- 법정 (세금)
  'INCOME_TAX',           -- 소득세 (간이세액)
  'LOCAL_INCOME_TAX',     -- 지방소득세 (소득세의 10%)
  -- 임의
  'COMPANY_LOAN',         -- 사내 대출 상환
  'UNION_FEE',            -- 노조비
  'OTHER'
);
```

> 산재보험 (`WORKERS_COMPENSATION`) 은 100% 사업주 부담이라 **deduction 대상 아님**. 회계 시스템 별도.

### EP-351. 법정 vs 임의 처리 차이

| 분류 | 요율 / 금액 출처 | 변경 빈도 | 검증 |
|---|---|---|---|
| 법정 (4대보험 / 세금) | `deduction_rates` 테이블 (연 1회 갱신) | 연 1회 | 시스템 강제 |
| 임의 (사내 / 노조) | `payroll_deduction_settings` (사용자별 / 시점별) | 수시 | 운영자 검증 |

---

## 2. 요율 관리 (EP-360 ~ EP-369) — MUST

### EP-360. deduction_rates 테이블 (MUST)

```sql
CREATE TABLE deduction_rates (
  id              UUID PRIMARY KEY,
  deduction_type  deduction_type NOT NULL,
  effective_year  INTEGER NOT NULL,                -- 2026
  rate_employee   NUMERIC(7, 5) NOT NULL,          -- 근로자 부담률 (e.g. 0.04500)
  rate_employer   NUMERIC(7, 5) NOT NULL DEFAULT 0,
  ceiling         NUMERIC(12, 0),                   -- 상한 (월소득 상한, NULL=없음)
  floor           NUMERIC(12, 0),                   -- 하한
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (deduction_type, effective_year)
);
```

매년 1월 적용 요율은 전년 12월까지 INSERT. 누락 시 1월 1일 계산 실패 (의도적 알림).

### EP-361. 요율 하드코딩 금지 (MUST)

```typescript
// ❌ 절대 금지
const NATIONAL_PENSION_RATE = 0.045;

// ✅ 정답
const rate = await db.deductionRate.findUnique({
  where: { deductionType_effectiveYear: { deductionType: 'NATIONAL_PENSION', effectiveYear: year }}
});
```

### EP-362. 갱신 시점 알림 (SHOULD)

매년 11월 1일 시점에 다음 해 요율 미입력이면 admin 대시보드 경고 + 메일 발송.

### EP-365. 참고 요율 (2026 예시, 실제 갱신 필요)

> ⚠️ 아래는 학습용 예시값. 운영 시 보건복지부 / 국세청 고시 직접 확인.

| 항목 | 근로자 | 사업주 | 비고 |
|---|---|---|---|
| 국민연금 | 4.5% | 4.5% | 월 보수 상한 (현재 ₩590만 추정) |
| 건강보험 | 3.545% | 3.545% | 보수월액 기준 |
| 장기요양 | 건강보험료 × 12.95% | (동) | 건강보험 부속 |
| 고용보험 | 0.9% | 0.9% + 기업규모별 가산 | |
| 산재보험 | **0%** | 업종별 (0.7%~) | 근로자 공제 안 함 |

---

## 3. 4대보험 계산 (EP-370 ~ EP-379)

### EP-370. 보수월액 정의 (MUST)

4대보험의 부과 기준 = "보수월액". 비과세 항목 (식대 등) 제외:

```typescript
function getInsuranceBase(record: PayrollRecord, allowances: Allowance[]): number {
  const taxableAllowance = allowances.reduce((s, a) => s + Number(a.taxableAmount), 0);
  return record.basePayment + taxableAllowance;
}
```

### EP-371. 국민연금 계산

```typescript
function calcNationalPension(base: number, rate: DeductionRate): number {
  // 상한 / 하한 적용
  const capped = Math.min(rate.ceiling ?? Infinity, Math.max(rate.floor ?? 0, base));
  return Math.round(capped * Number(rate.rateEmployee));
}
```

### EP-372. 건강보험 + 장기요양

```typescript
function calcHealthInsurance(base: number, healthRate, ltcRate): { health: number; ltc: number } {
  const health = Math.round(base * Number(healthRate.rateEmployee));
  const ltc    = Math.round(health * Number(ltcRate.rateEmployee));  // 건강보험료의 12.95%
  return { health, ltc };
}
```

### EP-375. 일용근로자 / 단시간 근로자 예외 (MUST)

- 1개월 미만 일용 → 국민연금 가입 제외
- 60시간 미만 단시간 → 4대보험 가입 제외 (예외 있음)

`compensation_settings.is_short_time` 플래그로 분기. 미적용 시 계산 skip.

### EP-376. 다음 달 부과 (정보)

4대보험은 통상 **이번 달 보수에 부과되어 다음 달 25일에 납부**. 공제는 이번 달 급여에서. 회계 시스템과 정합 시 유의.

### EP-378. 일용근로자 특례 분기 (MUST)

`is_day_laborer = TRUE` 인 경우 4대보험 처리는 본 룰이 아니라 `day_laborer.md` § EP-740 으로 분기:

- 1개월 미만 일용 → 국민연금 / 건강 / 장기요양 **공제 SKIP**
- 고용보험은 일용근로자도 가입 (별도 처리)
- 산재는 사업주 100% 부담 (일용직도 동일, 공제 X)

소득세도 일반 간이세액표 아닌 일용직 산식 (EP-720) 적용.

게이트: `payroll.day_laborer` 토글이 OFF 면 `is_day_laborer` 플래그 무시 (일반 처리).

---

## 4. 소득세 (EP-380 ~ EP-389)

### EP-380. 간이세액 기반 (MUST)

매월 원천징수 = 국세청 간이세액표 기준. 실제 세액은 연말정산에서 정산.

```sql
CREATE TABLE income_tax_simple_rates (
  id              UUID PRIMARY KEY,
  effective_year  INTEGER NOT NULL,
  base_min        NUMERIC(12, 0) NOT NULL,        -- 월 보수 구간 시작
  base_max        NUMERIC(12, 0) NOT NULL,         -- 구간 끝
  dependents      INTEGER NOT NULL,                -- 부양가족 수 (1~N)
  tax_amount      NUMERIC(12, 0) NOT NULL,         -- 해당 구간 세액
  UNIQUE (effective_year, base_min, dependents)
);
```

또는 외부 라이브러리 / 국세청 API.

### EP-381. 부양가족 수 (MUST)

`compensation_settings.dependents` (또는 별도 `tax_profile` 테이블) 에서 조회. 부양가족 수에 따라 세액이 다름.

```typescript
const taxRow = await db.incomeTaxSimpleRates.findFirst({
  where: {
    effectiveYear: year,
    baseMin: { lte: base },
    baseMax: { gte: base },
    dependents: Math.min(taxProfile.dependents, MAX_DEPENDENTS_IN_TABLE)
  }
});
const incomeTax = Number(taxRow?.taxAmount ?? 0);
```

### EP-382. 80% / 100% / 120% 옵션 (MUST)

근로자 신청에 따라 간이세액의 80% / 100% / 120% 선택 가능 (매월 부담 조절). `tax_profile.simple_rate_option`.

```typescript
const incomeTax = Math.round(baseAmount * option);  // 0.8 / 1.0 / 1.2
```

### EP-385. 지방소득세

소득세의 정확히 10%. 소득세 계산 후 별도 row:

```typescript
const localIncomeTax = Math.round(incomeTax * 0.1);
```

---

## 5. 임의 공제 (EP-388 ~ EP-389)

### EP-388. 사내 대출 / 노조비

```sql
CREATE TABLE payroll_deduction_settings (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  user_id         UUID NOT NULL,
  deduction_type  deduction_type NOT NULL,
  amount_type     VARCHAR(10) NOT NULL,            -- 'FIXED' / 'PERCENT'
  amount          NUMERIC(12, 2) NOT NULL,
  schedule        VARCHAR(20) NOT NULL,            -- 'MONTHLY' / 'ONCE'
  remaining       NUMERIC(12, 0),                   -- 남은 공제액 (loans)
  effective_from  DATE NOT NULL,
  effective_to    DATE,
  notes           TEXT
);
```

대출은 매월 차감 → `remaining` 감소 → 0 도달 시 자동 종료.

### EP-389. 임의 공제 한도 (MUST, KR)

근로기준법 §43 (임금 직접지급 원칙) — 임의 공제는 근로자 동의 + 단체협약 / 취업규칙 근거 필요. 시스템은 형식 강제 불가지만 `payroll_deduction_settings.consent_doc_url` 권장 필드.

---

## 6. 저장 / 검증 (EP-390 ~ EP-399)

### EP-390. payroll_deductions 항목별 row (MUST)

```sql
CREATE TABLE payroll_deductions (
  id              UUID PRIMARY KEY,
  record_id       UUID NOT NULL REFERENCES payroll_records(id) ON DELETE CASCADE,
  deduction_type  deduction_type NOT NULL,
  amount          NUMERIC(12, 0) NOT NULL,
  rate_used       NUMERIC(7, 5),                   -- 적용된 요율 (검증용)
  base_used       NUMERIC(12, 0),                  -- 적용 기준액
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (amount >= 0)
);
CREATE INDEX idx_payroll_deductions_record ON payroll_deductions(record_id);
```

### EP-391. 합계 검증 (MUST)

`payroll_records.total_deduction` = `SUM(payroll_deductions.amount where record_id=...)`. 불일치 시:

```typescript
await db.$transaction(async (tx) => {
  const sum = await tx.payrollDeduction.aggregate({
    where: { recordId: record.id },
    _sum: { amount: true }
  });
  if (Number(sum._sum.amount) !== Number(record.totalDeduction)) {
    throw new DeductionMismatchError(
      `record.total_deduction=${record.totalDeduction} ≠ items=${sum._sum.amount}`
    );
  }
});
```

### EP-395. 음수 공제 금지 (MUST)

`amount < 0` 은 거부. 환급은 별도 (allowance 의 음수 또는 환급 트랜잭션).

### EP-396. 요율 / 베이스 보존 (SHOULD)

`rate_used` / `base_used` 를 함께 저장하면 사후 분쟁 시 어떤 요율로 계산됐는지 추적 가능. 요율 표가 변경되어도 과거 record 는 자체 보존된 값으로 검증.

---

## 7. 참조

- 통상임금 / 보수월액: `salary_calc.md`
- 4대보험 요율 갱신: 보건복지부 / 국세청 고시
- 다음: 명세서 → `payslip.md`
- 스키마: `../schemas/tables/payroll_deductions.sql`
