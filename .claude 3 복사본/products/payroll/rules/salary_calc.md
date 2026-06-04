# 급여 계산 (Salary Calculation)

> **ID 범위**: EP-200 ~ EP-299
> **주제**: 월급제 / 일급제 / 시급제 / 연봉제 / 통상임금 / 평균임금
> **상위**: `INDEX.md`
> **기준법**: 근로기준법 (KR), 최저임금법 (KR)

---

## TL;DR

- **4가지 급여 체계**: 월급제 / 일급제 / 시급제 / 연봉제. 사용자별 `compensation_settings` 에서 선택.
- **통상임금 (KR, MUST)**: 시간외 / 야간 / 휴일 수당의 베이스. 산정 공식은 EP-220.
- **최저임금 검증 (MUST)**: 시급 환산 < 최저시급 → INSERT 거부 (현재 KR 2026 = ₩10,860 추정, 실제 적용 시 검증 필요).
- **계산 결과는 `payroll_records`** (사용자별 / 월별 1 row). `work_logs` 는 사실, `records` 는 계산.
- **계산 멱등성** — 같은 month / 같은 입력으로 재실행해도 같은 결과. 입력이 바뀌면 새 version row.
- **확정(`finalized_at`) 후 수정 금지**. 정정은 다음 월 ADJUSTMENT (EP-140) 와 동일 패턴.

핵심 ID: EP-200 (체계 구분) / EP-220 (통상임금) / EP-240 (최저임금 검증) / EP-260 (records)

---

## 1. 급여 체계 (EP-200 ~ EP-219)

### EP-200. 5가지 체계 (MUST)

| 체계 | 영문 | base_amount 의미 | 계산 단위 | 비고 |
|---|---|---|---|---|
| 월급제 | `MONTHLY` | 월 지급액 | 월별 | 정규직 기본 |
| 일급제 | `DAILY` | 1일 지급액 | 출근일 수 | |
| 시급제 | `HOURLY` | 1시간 지급액 | 근무 시간 | |
| 연봉제 | `ANNUAL` | 연간 총액 | 월별 (annual / 12) | |
| **단가제** | **`PIECEWORK`** | **(미사용 — task_definitions 참조)** | **건/개/km/상자** | **`piecework.md`** 게이트: `payroll.piecework` |

`compensation_settings` 테이블에 사용자별로 1 row.

```sql
CREATE TABLE payroll_compensation_settings (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  user_id         UUID NOT NULL,
  scheme          compensation_scheme NOT NULL,
  base_amount     NUMERIC(12, 0) NOT NULL,
  effective_from  DATE NOT NULL,
  effective_to    DATE,                       -- NULL = 현재 유효
  notes           TEXT,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, effective_from)
);
```

이력 보존: `effective_to` 로 마감, 새 row INSERT. UPDATE 금지.

### EP-201. 시점 조회 (MUST)

특정 일자의 보수 설정 조회는 시점 기준:

```sql
SELECT * FROM payroll_compensation_settings
WHERE user_id = $1
  AND effective_from <= $date
  AND (effective_to IS NULL OR effective_to >= $date)
LIMIT 1;
```

### EP-205. 변경은 항상 새 row (MUST)

연봉 인상 / 시급 변경 시:
1. 기존 row 의 `effective_to` 를 어제 날짜로 UPDATE
2. 새 row INSERT (새 effective_from)
3. 감사 로그 (변경자 / before / after)

UPDATE 한 번으로 base_amount 만 바꾸는 패턴 금지. 과거 시점 조회 깨짐.

### EP-210. 연봉제 → 월 분할

연봉제 사용자의 월 base = `annual / 12`. 단순 나눗셈 (균등 분할).

격월 / 분기 / 상여 분할은 별도 `bonus_schedule` 테이블 (Phase 2+).

---

## 2. 통상임금 / 평균임금 (EP-220 ~ EP-229) — MUST, KR

### EP-220. 통상임금 시급 (MUST, KR)

수당 계산의 기준. 근로기준법 시행령 §6 기준 단순 모델:

| 체계 | 통상임금 시급 산식 |
|---|---|
| 월급제 (월 209시간 기준) | `base_amount / 209` |
| 일급제 | `base_amount / 일소정근로시간 (기본 8h)` |
| 시급제 | `base_amount` (그대로) |
| 연봉제 | `(annual / 12) / 209` |

> 209시간 = (40시간 + 8시간 주휴) × 4.345주 = 209.16h ≈ 209h.
> 사업장 표준이 다르면 (예: 월 226h, 월 173h) `organization.standard_monthly_hours` 로 override 가능.

```typescript
function ordinaryHourlyWage(s: CompensationSetting, org: Org): number {
  const stdH = org.standardMonthlyHours ?? 209;
  switch (s.scheme) {
    case 'MONTHLY': return s.baseAmount / stdH;
    case 'DAILY':   return s.baseAmount / (org.dailyStandardHours ?? 8);
    case 'HOURLY':  return s.baseAmount;
    case 'ANNUAL':  return (s.baseAmount / 12) / stdH;
  }
}
```

### EP-221. 통상임금 ≠ base_amount

통상임금은 시급 단위 비교 가능 값. base_amount 그대로 쓰면 체계가 다른 사용자 비교 / 수당 계산 불가.

### EP-225. 평균임금 (MUST, KR)

해고예고수당 / 퇴직금 등 산정 시 별도 평균임금 사용:

```
평균임금 = 산정 사유 발생 직전 3개월 임금총액 / 3개월 일수
```

평균임금은 **on-demand 계산** (테이블에 영속화하지 않음). 호출자가 시점과 사유를 지정.

---

## 3. 최저임금 검증 (EP-240 ~ EP-249) — MUST, KR

### EP-240. 시급 환산 검증 (MUST)

`compensation_settings` INSERT 전에 통상임금 시급으로 환산해서 최저임금 검증:

```typescript
function validateMinWage(setting: CompensationSetting, org: Org, year: number) {
  const minWage = MIN_WAGE_KR[year];   // ₩10,860 (2026 가정)
  const hourly = ordinaryHourlyWage(setting, org);
  if (hourly < minWage) {
    throw new BelowMinWageError(
      `시급 환산 ₩${hourly.toFixed(0)} 가 ${year}년 최저시급 ₩${minWage} 미만`
    );
  }
}
```

> ⚠️ `MIN_WAGE_KR` 상수는 매년 갱신. 8월 고시 후 다음해 1월 적용. 갱신 누락 = 위법 소지.

### EP-241. 갱신 시점 알림 (SHOULD)

매년 9월 1일 시점에 다음 해 최저임금 미반영이면 admin 알림 / 대시보드 경고.

### EP-242. 환산 시 수당 포함 (MUST)

최저임금 비교 시 일부 고정 수당은 통상임금에 포함 (식대 일부 등). 단순 base_amount 만 보면 위법 판정 회피 → 정확한 산입은 사업장 노무 정책 필요. **기본 구현은 base_amount 만 검증** + 노무 자문 권고 표시.

---

## 4. 월별 계산 (EP-260 ~ EP-279)

### EP-260. payroll_records 모델 (MUST)

```sql
CREATE TABLE payroll_records (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  user_id         UUID NOT NULL,
  month           CHAR(7) NOT NULL,              -- 'YYYY-MM'
  scheme          compensation_scheme NOT NULL,
  base_amount     NUMERIC(12, 0) NOT NULL,       -- 해당 월 시작 시점의 base
  ordinary_hourly NUMERIC(12, 2) NOT NULL,       -- 통상임금 시급
  worked_minutes  INTEGER NOT NULL DEFAULT 0,    -- 실 근무 분
  worked_days     INTEGER NOT NULL DEFAULT 0,    -- 출근 일수
  base_payment    NUMERIC(12, 0) NOT NULL,       -- 본급 (계산값)
  total_allowance NUMERIC(12, 0) NOT NULL DEFAULT 0,
  total_deduction NUMERIC(12, 0) NOT NULL DEFAULT 0,
  net_payment     NUMERIC(12, 0) NOT NULL,       -- base + allowance - deduction
  status          payroll_record_status NOT NULL DEFAULT 'DRAFT',
  finalized_at    TIMESTAMPTZ,                   -- 확정 시각
  finalized_by    UUID,
  version         INTEGER NOT NULL DEFAULT 1,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, month, version)
);

CREATE TYPE payroll_record_status AS ENUM (
  'DRAFT',       -- 계산만, 미확정
  'FINALIZED',   -- 확정 (수정 금지)
  'PAID',        -- 지급 완료
  'VOIDED'       -- 무효화 (정정용 새 version 발행)
);
```

### EP-261. 계산 입력

월별 계산은 다음 4가지 입력으로:

1. `compensation_settings` (해당 월 시작 시점 active)
2. `work_logs` (status=ACTIVE 또는 AGGREGATED, 해당 월 date)
3. `payroll_attendance` (해당 월) — 일급/시급 환산용
4. `allowances`, `deductions` 설정

### EP-262. 본급 계산 (체계별, MUST)

```typescript
function calcBasePayment(
  setting: CompensationSetting,
  workLogs: WorkLog[],
  attendance: Attendance[],
  org: Org
): { base: number; workedMin: number; workedDays: number } {
  switch (setting.scheme) {
    case 'MONTHLY':
    case 'ANNUAL': {
      // 월급/연봉은 출근율 기반 일할
      const workedDays = attendance.filter(a => isPresent(a)).length;
      const standardDays = workingDaysOfMonth(setting.month, org);
      const base = Math.round(
        (setting.scheme === 'ANNUAL' ? setting.baseAmount / 12 : setting.baseAmount)
        * (workedDays / standardDays)
      );
      return { base, workedMin: 0, workedDays };
    }
    case 'DAILY': {
      const workedDays = attendance.filter(a => isPresent(a)).length;
      return { base: setting.baseAmount * workedDays, workedMin: 0, workedDays };
    }
    case 'HOURLY': {
      const workedMin = attendance.reduce((s, a) => s + netMinutes(a), 0);
      const base = Math.round((workedMin / 60) * setting.baseAmount);
      return { base, workedMin, workedDays: attendance.filter(isPresent).length };
    }
    case 'PIECEWORK': {
      // base_amount 미사용. work_logs (source_type=PIECEWORK) 의 amount 합계가 base.
      // 상세는 piecework.md (EP-800~)
      const pieceworkLogs = workLogs.filter(w => w.sourceType === 'PIECEWORK' && w.status === 'ACTIVE');
      const base = pieceworkLogs.reduce((s, w) => s + Number(w.amount), 0);
      const workedMin = attendance.reduce((s, a) => s + netMinutes(a), 0);  // 시간외/최저임금 검증용
      return { base, workedMin, workedDays: attendance.filter(isPresent).length };
    }
  }
}
```

> ⚠️ **일용근로자 케이스**: `is_day_laborer = TRUE` 면 record 의 `period_type = 'DAILY'` 또는 `'WEEKLY'` 가 일반적. 원천징수 / 4대보험 / 명세서 처리 모두 다름 → `day_laborer.md` (EP-700~) 분기.

### EP-263. WorkLog 가산

배송 / 추가 작업 등 `work_logs` 의 `amount` 합계는 본급 위에 더해짐:

```typescript
const workLogTotal = workLogs
  .filter(w => w.status === 'AGGREGATED' && w.month === month)
  .reduce((s, w) => s + Number(w.amount), 0);

const totalGross = base + workLogTotal + totalAllowance;
const netPayment = totalGross - totalDeduction;
```

### EP-265. 계산 멱등성 (MUST)

같은 입력 (compensation_settings + attendance + work_logs + allowances + deductions 조합) 으로 재실행하면 결과 동일. 결과가 같으면 INSERT 안 하고 skip (또는 새 version 발행 안 함).

```typescript
const newHash = hashOfInputs({ setting, attendance, workLogs, allowances, deductions });
const existing = await db.payrollRecord.findFirst({
  where: { userId, month, version: { /* 최신 */ } }
});
if (existing && existing.inputHash === newHash) return existing;
// 다르면 새 version row INSERT
```

### EP-270. 확정 (FINALIZED)

DRAFT → FINALIZED 는 L4 승인 작업. `finalized_at` / `finalized_by` 기록.

FINALIZED 후 수정 시도는 거부. 정정은 새 version (status=DRAFT) 발행 + 기존 row 를 VOIDED 마킹.

### EP-275. 지급 (PAID)

별도 payment 트랜잭션 (`payment.md` 참조) 에서 status='PAID' 로 전이. PAID 도 마찬가지 수정 금지.

---

## 5. 발행 이벤트 (EP-280 ~ EP-289)

| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `payroll.record.calculated` | DRAFT 생성 / 갱신 | userId / month / netPayment |
| `payroll.record.finalized` | DRAFT → FINALIZED | userId / month / finalizedBy |
| `payroll.record.voided` | FINALIZED → VOIDED (정정용) | userId / month / oldVersion |

Outbox 패턴 적용 (`integration.md` § E-830).

---

## 6. 권한 (EP-290 ~ EP-299)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 record 조회 | ✅ (마스킹 해제) | ✅ | ✅ | ✅ | ⚠️ |
| 팀원 record 조회 (마스킹) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 팀원 record 조회 (금액) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| compensation_settings 변경 | ❌ | ❌ | ✅ (반려권) | ✅ | ⚠️ |
| 월별 계산 실행 (DRAFT) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| FINALIZED 승인 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| VOIDED 처리 (정정) | ❌ | ❌ | ❌ | ✅ | ⚠️ |

---

## 7. 참조

- 통상임금 산정 근거: 근로기준법 시행령 §6
- 최저임금 갱신: 매년 8월 고시
- 권한 / 마스킹: `../../../rules/permissions.md` § E-420
- 다음: 수당 → `allowance.md`, 공제 → `deduction.md`, 명세서 → `payslip.md`
- 스키마: `../schemas/tables/payroll_records.sql`, `../schemas/tables/payroll_compensation_settings.sql`
