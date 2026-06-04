# 수당 (Allowance)

> **ID 범위**: EP-300 ~ EP-349
> **주제**: 시간외 / 야간 / 휴일 / 식대 / 직책 / 위험 수당
> **상위**: `INDEX.md`
> **기준법**: 근로기준법 §56 (가산수당)

---

## TL;DR

- **수당 = base 위에 추가되는 지급액**. 통상임금 시급 (EP-220) 의 가산율로 계산.
- **법정 가산수당 (KR, MUST)**: 시간외 / 야간 / 휴일 — 통상임금 50% 가산. 시간외 + 야간 중복 시 합산 (100% 가산).
- **임의 수당** (식대 / 차량 / 직책): 정액 또는 정률. 사업장 정책으로 자유 정의.
- **연차미사용수당** (KR): 별도 정산 사이클. 매월 누적 X, 회계연도 마감 시 일괄.
- **수당은 `payroll_records.total_allowance` 에 합산** + 항목별로 `payroll_allowances` 에 분리 저장 (명세서용).
- **권한**: 설정은 L3+, 조회는 record 와 동일 (L1 본인 / L2 마스킹 / L3+ 원본).

핵심 ID: EP-310 (법정 가산) / EP-320 (시간외) / EP-325 (야간) / EP-330 (휴일) / EP-340 (임의수당)

---

## 1. 수당 분류 (EP-300 ~ EP-309)

### EP-300. 2 갈래 (MUST)

| 분류 | 예 | 가산 기준 |
|---|---|---|
| **법정 가산수당** | 시간외 / 야간 / 휴일 | 통상임금 시급 × 가산율 (법정) |
| **임의 수당** | 식대 / 차량 / 직책 / 위험 | 사업장 정책 (정액 / 정률) |

### EP-301. allowance_type 카탈로그

```sql
CREATE TYPE allowance_type AS ENUM (
  -- 법정
  'OVERTIME',           -- 시간외 (연장)
  'NIGHT',              -- 야간 (22:00 ~ 06:00)
  'HOLIDAY',            -- 휴일
  'WEEKLY_HOLIDAY',     -- 주휴수당
  'ANNUAL_LEAVE_UNUSED',-- 연차미사용수당
  -- 임의
  'MEAL',
  'TRANSPORT',
  'POSITION',           -- 직책수당
  'HAZARD',             -- 위험수당
  'BONUS',
  'OTHER'
);
```

새 타입 추가 시 마이그레이션 필요. 사업장 특수 수당은 `OTHER` + `notes` 권장.

---

## 2. 법정 가산수당 (EP-310 ~ EP-339) — MUST, KR

### EP-310. 가산율 표 (MUST, KR)

근로기준법 §56:

| 유형 | 가산율 | 조건 |
|---|---|---|
| 시간외 (연장) | **+50%** | 1주 40시간 / 1일 8시간 초과 |
| 야간 | **+50%** | 22:00 ~ 익일 06:00 근무 |
| 휴일 (8시간 이내) | **+50%** | 법정 / 약정 휴일 근무 |
| 휴일 (8시간 초과분) | **+100%** | 휴일 + 8시간 초과분 |
| 시간외 + 야간 (중복) | **+100%** (50+50) | 동시 발생 시 합산 |
| 휴일 + 야간 (중복) | **+100%** | 동시 발생 시 합산 |

### EP-320. 시간외 (Overtime)

#### 산정 공식

```typescript
function calcOvertimeAllowance(
  overtimeMinutes: number,
  ordinaryHourly: number,
): number {
  const hours = overtimeMinutes / 60;
  return Math.round(hours * ordinaryHourly * 0.5);
}
```

#### 시간외 식별

attendance 의 `(check_out_at - check_in_at - breaks)` 가:
- 1일 480분 (8h) 초과 분 → 시간외
- 또는 주 2400분 (40h) 초과 분 → 시간외

> ⚠️ 일 / 주 양쪽 한도가 동시에 적용. 일 8h 미만이어도 주 40h 넘으면 시간외. 정확한 산정은 일 단위 + 주 단위 누적 양쪽 검증.

#### EP-321. 5인 미만 사업장 예외 (MUST)

근로기준법 §11 — 상시 근로자 5인 미만 사업장은 시간외/야간/휴일 가산수당 적용 제외.

```typescript
if (org.headcount < 5) {
  // 가산수당 미적용 (단, 통상임금 시급 그대로는 지급)
  return ordinaryHourly * (overtimeMinutes / 60);
}
```

`organization.headcount_threshold_5` 플래그로 명시.

### EP-325. 야간 (Night)

22:00 ~ 익일 06:00 사이 근무 시간 분 단위 합산:

```typescript
function nightMinutesOfShift(checkIn: Date, checkOut: Date, breaks: Break[]): number {
  // 22:00~06:00 와 (checkIn~checkOut - breaks) 의 교집합
  // ...구현 생략 (분 단위 정확)
}
```

야간 자체 가산 +50% + 시간외와 중첩 시 **양쪽 모두** 가산.

### EP-330. 휴일 (Holiday)

#### EP-331. 휴일 정의

- **법정 휴일**: 근로자의 날 (5/1), 공휴일 (관공서 공휴일에 관한 규정), 일요일 (주휴일 — 사업장 약정에 따름)
- **약정 휴일**: 사업장 단협 / 취업규칙으로 정한 추가 휴일

`holiday_calendar` 테이블 (별도, Phase 2+) 또는 organization 설정으로 관리.

#### EP-332. 휴일 8시간 분기

```typescript
const holidayMin = workedMinutesOnHoliday;
const within8h = Math.min(holidayMin, 480);
const over8h   = Math.max(0, holidayMin - 480);

const allowance =
    Math.round((within8h / 60) * ordinaryHourly * 0.5)    // +50%
  + Math.round((over8h / 60) * ordinaryHourly * 1.0);     // +100%
```

#### EP-335. 주휴수당 (Weekly Holiday Pay)

소정 근로일 개근 → 주 1일 유급 휴일 (1일분 통상임금 추가 지급).

- 1주 15시간 미만 근무자 제외
- 결근 1회 → 주휴수당 미발생

월급제는 통상 base_amount 에 주휴수당이 포함된 것으로 간주 (월 209시간 = 40 + 8주휴 × 4.345). 시급/일급제는 별도 계산.

### EP-336. 연차미사용수당

회계연도 마감 시 미사용 연차 × 통상임금 1일분.

별도 정산 트랜잭션. 매월 record 에 자동 포함하지 않음. 연 1회 (사업장 회계연도 종료 시) 일괄 발생.

---

## 3. 임의 수당 (EP-340 ~ EP-349)

### EP-340. 정액 / 정률

```sql
CREATE TABLE payroll_allowance_settings (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  user_id         UUID,                            -- NULL = 조직 / 시설 / 팀 레벨
  facility_id     UUID,
  team_id         UUID,
  allowance_type  allowance_type NOT NULL,
  amount_type     VARCHAR(10) NOT NULL,            -- 'FIXED' / 'PERCENT'
  amount          NUMERIC(12, 2) NOT NULL,         -- FIXED=KRW, PERCENT=%
  effective_from  DATE NOT NULL,
  effective_to    DATE,
  notes           TEXT,
  CHECK (amount_type IN ('FIXED', 'PERCENT'))
);
```

### EP-341. 적용 우선순위 (MUST)

같은 allowance_type 에 대해 여러 설정 존재 시:

```
user > team > facility > organization
```

상위 (user) 가 있으면 하위는 무시. 합산하지 않음.

### EP-342. PERCENT 베이스

`amount_type='PERCENT'` 의 베이스는 base_amount (월급) 또는 통상임금. `notes` 에 기준 명시 권장.

### EP-345. 식대 (Meal)

KR 비과세 한도 (현재 월 ₩200,000) 까지 비과세. 초과분은 과세. 공제(소득세) 계산에서 비과세 금액 분리.

```sql
ALTER TABLE payroll_allowances ADD COLUMN nontaxable_amount NUMERIC(12, 0) DEFAULT 0;
```

> ⚠️ 비과세 한도는 세법 개정으로 변경. 현재 식대 한도는 2024 개정 기준.

---

## 4. 저장 (EP-350 도달 직전, allowance 영역 끝)

### EP-348. payroll_allowances 항목별 row (MUST)

`payroll_records.total_allowance` 는 합산값. 항목별 분리는 `payroll_allowances` 테이블:

```sql
CREATE TABLE payroll_allowances (
  id              UUID PRIMARY KEY,
  record_id       UUID NOT NULL REFERENCES payroll_records(id) ON DELETE CASCADE,
  allowance_type  allowance_type NOT NULL,
  amount          NUMERIC(12, 0) NOT NULL,
  taxable_amount  NUMERIC(12, 0) NOT NULL,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payroll_allowances_record ON payroll_allowances(record_id);
```

명세서 / 보고서에서 항목별로 표시.

### EP-349. record 갱신 시 동시 갱신 (MUST)

`payroll_records` 가 새 version 으로 교체되면 `payroll_allowances` 도 새 row. ON DELETE CASCADE 로 정리.

같은 트랜잭션 안에서 INSERT. 부분 업데이트 금지.

---

## 5. 참조

- 통상임금 시급: `salary_calc.md` § EP-220
- 휴일 캘린더 (Phase 2+): `holiday_calendar` 테이블 별도
- 다음: 공제 → `deduction.md`
- 스키마: `../schemas/tables/payroll_allowances.sql`
