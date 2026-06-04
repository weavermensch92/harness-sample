# 일용근로자 (Day Laborer)

> **ID 범위**: EP-700 ~ EP-799
> **주제**: 한국 세법상 일용근로자 특례 (원천징수 / 4대보험 / 즉시 지급 / 간이명세서)
> **상위**: `INDEX.md`
> **기준법**: 소득세법 §14, §47, §134 / 근로기준법 §11 / 국민연금법 §6 / 건강보험법 §6
> **게이트 토글**: `payroll.day_laborer` (`feature_flags.md` § EP-900). OFF 면 이 룰 전체 비활성.

---

## TL;DR

- **일용근로자 정의 (KR)**: 동일 사업장에서 **3개월 미만** 고용 + 일급 / 시급으로 임금 받는 자. 3개월 초과 = 상용근로자.
- **원천징수 (MUST)**: `(일당 - ₩150,000) × 6.6% × 45%` = `(일당 - 150,000) × 2.97%`. 비과세 일급 ₩150,000 / 소액부징수 (일당 ₩187,000 미만 시 면제).
- **분리과세 종결**: 연말정산 / 종합과세 X. 매월 / 분기마다 신고로 끝.
- **4대보험 가입 예외**: 1개월 미만 일용 → 국민연금 / 건강 / 장기요양 가입 제외. 고용보험은 일용직도 가입 (일용근로 EI). 산재는 자동 가입 (사업주 부담).
- **즉시 지급 가능**: 당일 / 주 / 월 사이클 선택 가능 (원칙: 매월 1회 이상, KR §43 ④ 단서 — 임시지급 가능).
- **간이지급명세서**: 분기 마지막 달 다음 달 말일까지 신고. 일용근로 지급명세서 별도 양식.
- **scheme 무관**: HOURLY / DAILY / PIECEWORK 어느 체계든 일용직 플래그 단독으로 적용.

핵심 ID: EP-710 (정의) / EP-720 (원천징수 산식) / EP-730 (4대보험 예외) / EP-740 (즉시 지급) / EP-750 (간이명세서)

---

## 1. 정의 / 식별 (EP-700 ~ EP-719)

### EP-700. 일용근로자 정의 (MUST, KR)

소득세법 §14 ③ 2호 + 시행령 §20:
> 동일한 고용주에게 **계속하여 3개월 이상 고용되지 아니한 자**로서 일급 또는 시간급으로 임금을 받는 자.

판단 기준:
- 동일 사업장 누적 근무 기간 < 3개월 → 일용
- 3개월 초과 시점에 자동으로 상용 전환 (소득세 처리도 변경)

### EP-710. 식별 플래그 (MUST)

`payroll_compensation_settings.is_day_laborer = TRUE` 인 사용자를 일용근로자로 처리.

```sql
ALTER TABLE payroll_compensation_settings
  ADD COLUMN is_day_laborer BOOLEAN NOT NULL DEFAULT FALSE;
```

### EP-711. 자동 전환 (MUST)

3개월 초과 누적 근무 시 자동 알림 + 운영자 확인 후 `is_day_laborer = FALSE` 전환:

```typescript
// 일배치: 일용직의 누적 근무일 체크
const cumulativeDays = await db.payrollAttendance.count({
  where: { userId, source: { not: 'manual_admin' }, deletedAt: null }
});
if (cumulativeDays >= 90) {
  await sendAlert(`${user.name} 누적 ${cumulativeDays}일 — 상용 전환 검토 필요`);
}
```

자동 전환은 **알림만**, 실제 변경은 운영자 명시 액션 (소득세 신고 영향 큼).

### EP-712. scheme 과 직교 (MUST)

`is_day_laborer` 는 scheme 과 독립:
- 일용직 + DAILY: 일급제 일용근로자 (예: 건설 현장)
- 일용직 + HOURLY: 시급제 일용근로자 (예: 단시간 알바)
- 일용직 + PIECEWORK: 단가제 일용근로자 (예: 도급 작업)
- 일용직 + MONTHLY/ANNUAL: **금지** (월급제는 상용)

```sql
ALTER TABLE payroll_compensation_settings
  ADD CONSTRAINT ck_compensation_day_laborer_scheme
  CHECK (
    NOT is_day_laborer OR scheme IN ('DAILY', 'HOURLY', 'PIECEWORK')
  );
```

---

## 2. 원천징수 (EP-720 ~ EP-739) — MUST, KR

### EP-720. 산식 (MUST)

소득세법 §134 ② + 시행령 §189:

```
소득세       = (일당 - 150,000) × 6%  × 45%
지방소득세    = 소득세 × 10%
총 원천징수액 = 소득세 + 지방소득세
            = (일당 - 150,000) × 6.6% × 45%
            = (일당 - 150,000) × 2.97%
```

> 6% × 45% = 2.7% (소득세) / 0.6% × 45% = 0.27% (지방세) / 합 2.97%

### EP-721. 변수 의미

| 변수 | 의미 | 출처 |
|---|---|---|
| 6% | 일용근로자 적용 세율 | 소득세법 §129 ① 4호 |
| 150,000 | 비과세 일급 한도 | 소득세법 §47 ② |
| 45% | 근로소득세액공제 (55% 공제) | 소득세법 §59 ① 일용 |

세 변수 모두 `deduction_rates` 테이블에 보관 (하드코딩 금지, EP-361 동일):

```sql
INSERT INTO deduction_rates (deduction_type, effective_year, rate_employee, ceiling, notes)
VALUES
  ('INCOME_TAX_DAY_LABORER', 2026, 0.060, NULL, '일용직 소득세율'),
  ('LOCAL_INCOME_TAX', 2026, 0.10, NULL, '소득세의 10%'),
  -- 추가: 비과세 한도 / 공제율은 별도 day_laborer_settings 테이블 또는 organization 설정
;
```

### EP-722. 소액부징수 (MUST)

소득세법 §86 — 매월 원천징수세액이 1,000원 이하면 징수 안 함.

일용직 소득세 ≤ 1,000원 → 면제:
```
(일당 - 150,000) × 6% × 45% ≤ 1,000
(일당 - 150,000) × 0.027   ≤ 1,000
일당 - 150,000             ≤ 37,037
일당                       ≤ 187,037
```

**결론: 일당 ₩187,000 미만은 소득세 면제. 지방소득세도 자동 면제 (소득세 0).**

```typescript
function calcDayLaborerTax(dailyAmount: number): { incomeTax: number; localTax: number } {
  if (dailyAmount <= 150_000) return { incomeTax: 0, localTax: 0 };
  const taxableBase = dailyAmount - 150_000;
  const incomeTaxRaw = Math.floor(taxableBase * 0.06 * 0.45);
  if (incomeTaxRaw <= 1_000) return { incomeTax: 0, localTax: 0 };  // 소액부징수
  const localTax = Math.floor(incomeTaxRaw * 0.10);
  return { incomeTax: incomeTaxRaw, localTax };
}
```

### EP-725. 분리과세 종결 (MUST)

일용근로소득은:
- **종합과세 합산 X** — 다른 소득과 별개
- **연말정산 X** — 매월 / 분기 신고로 종결
- 근로자 입장에서 추가 세 부담 / 환급 기회 없음

따라서 시스템에서 일용직 record 는:
- 별도 `is_day_laborer_record` 플래그 또는 `period_type = 'DAILY'` 로 식별
- 연말정산 처리 대상에서 제외

### EP-730. 일급 vs 합산 일급

원천징수는 **개별 일당** 단위. 같은 사업장에서 한 달에 5일 근무한 일용직이면:
```
5일 × 각 일당 → 각각 (일당 - 150,000) × 2.97% 계산 → 5건 합산 신고
```

5일을 합산해서 일급 평균 계산 X. 매일이 독립 사건.

---

## 3. 4대보험 예외 (EP-740 ~ EP-749) — MUST, KR

### EP-740. 가입 매트릭스

| 보험 | 일용직 가입 여부 | 근거 |
|---|---|---|
| **국민연금** | 1개월 미만 일용 = **제외**, 1개월 이상 = 가입 | 국민연금법 §6 |
| **건강보험** | 1개월 미만 일용 = **제외**, 1개월 이상 = 가입 (직장 / 지역 분기) | 건강보험법 §6 |
| **장기요양** | 건강보험 종속 | (건강보험과 동일) |
| **고용보험** | 일용직도 **가입** (일용근로자용 EI 처리) | 고용보험법 §10 |
| **산재보험** | 모든 근로자 자동 가입 (사업주 100% 부담, 공제 X) | 산재법 §6 |

### EP-741. 1개월 미만 판정 (MUST)

"1개월 미만" 은 **고용계약 / 실제 근무 기간**:
- 1개월 미만 단발성 일용 → 국민연금 / 건강보험 제외
- 같은 사업장에서 같은 사람을 1개월 이상 일용 → 가입 의무 발생 시점부터 가입

시스템 처리:
- `compensation_settings.is_day_laborer = TRUE` + `effective_from` 부터 30일 미만 = 4대보험 공제 skip
- 30일 도달 시 알림 + 가입 처리 안내

### EP-745. 고용보험 일용 처리 (MUST)

일용근로자도 고용보험 가입 → 매일 / 매월 신고:
- 일용근로내역신고서 (월별 다음 달 15일까지 근로복지공단)
- 고용보험료 = 일급 × 0.9% (근로자 부담분, 2026 기준 — 매년 갱신)

```typescript
// 일용직 work_log 생성 시 고용보험 자동 공제
if (settings.isDayLaborer) {
  const employmentInsurance = Math.round(dailyAmount * eiRate);
  // payroll_deductions 에 EMPLOYMENT_INSURANCE row INSERT
}
```

---

## 4. 즉시 지급 (EP-750 ~ EP-769)

### EP-750. 지급 사이클 (MUST)

근로기준법 §43 ④ — 임금은 매월 1회 이상 정기지급. 단서: **임시 지급 가능**.

일용근로자 일반 패턴:
- **DAILY**: 당일 작업 종료 후 즉시 지급 (건설 현장 / 농장)
- **WEEKLY**: 주 1회 (월~금 누적 → 토요일 지급)
- **MONTHLY**: 정기 월급일에 일괄 (정규직과 동일 사이클)
- **IMMEDIATE**: 작업 / 배송 완료 직후 (배송 기사 등)

`payroll_compensation_settings.payment_cycle` 컬럼 추가:

```sql
ALTER TABLE payroll_compensation_settings
  ADD COLUMN payment_cycle VARCHAR(10) NOT NULL DEFAULT 'MONTHLY';
-- 'DAILY' / 'WEEKLY' / 'MONTHLY' / 'IMMEDIATE'
```

또는 `payroll_payments.payment_cycle` 에 기록 (record 단위).

### EP-751. 즉시 지급 트리거 (MUST)

`payment_cycle = DAILY / IMMEDIATE` 인 일용직:
- WorkLog 생성 → 자동 record DRAFT 생성 → 자동 FINALIZED → 자동 PAID 시도
- 자동 흐름은 cron 또는 이벤트 핸들러
- 운영자 승인 단계 SKIP (단, 토글 `payroll.day_laborer_auto_finalize` 별도 — 기본 OFF)

### EP-752. 일배치 자동 흐름 (SHOULD)

```
매일 23:59 cron:
  1. 오늘 ACTIVE 인 일용직 work_logs 조회
  2. 사용자별 / 작업일별 records 생성 (DRAFT)
  3. payment_cycle = DAILY 인 record 자동 FINALIZED
  4. payment 트랜잭션 시작 (Saga, 다음 영업일 새벽 처리)
```

자동 처리는 운영자 화면에서 결과 확인 가능 (audit).

### EP-755. 정정 / 환수 차감 한도 (MUST, KR)

근로기준법 §43 ② — 임금 1/4 초과 공제 금지. **일용직도 동일**:

일용직의 환수는 다음 일급에서 1/4 차감:
- 일당 ₩200,000 일용직 → 환수 시 최대 ₩50,000/일 차감

연속 차감 가능. 명시 동의 권고.

---

## 5. 간이지급명세서 (EP-770 ~ EP-789) — MUST, KR

### EP-770. 신고 의무 (MUST)

소득세법 §164 + 시행령 §214 — 일용근로 지급명세서:
- 분기 마지막 달의 다음 달 **말일까지** 국세청 신고
- 분기 = 1~3월 / 4~6월 / 7~9월 / 10~12월
- 신고 누락 = 가산세 (지급액 × 1%)

신고 주기 표:

| 지급 분기 | 신고 기한 |
|---|---|
| 1Q (1~3월) | 4월 30일 |
| 2Q (4~6월) | 7월 31일 |
| 3Q (7~9월) | 10월 31일 |
| 4Q (10~12월) | 다음 해 1월 31일 |

### EP-771. 명세서 양식 (MUST)

일용근로 지급명세서는 별도 양식 (소득세법 시행규칙 별지 제24호 서식). 일반 근로 명세서와 다름:

필수 항목:
1. 사업자등록번호 / 상호 / 대표자
2. 근로자 성명 / 주민등록번호
3. 지급일 / 일급 / 비과세 / 과세 일급
4. 원천징수 소득세 / 지방소득세
5. 분기별 합계

시스템:
- 분기 단위 자동 집계 → CSV / XML 내보내기
- 국세청 홈택스 일괄 업로드 형식 지원 (Phase 2+)

### EP-775. 실시간 명세서 vs 분기 신고 (MUST)

근로기준법 §48 의 임금명세서 (`payslip.md` EP-410) 는 **매 지급 시 교부 의무**. 일용직도 예외 없음.

따라서:
- **매 일용 지급 시**: 임금명세서 (간략 형태) — 본인용
- **분기마다**: 일용근로 지급명세서 — 국세청 신고용

두 가지는 **별개**. 데이터 중복이지만 양식 / 목적 다름.

`payroll_payslips.payslip_type` 컬럼 추가:
```sql
ALTER TABLE payroll_payslips
  ADD COLUMN payslip_type VARCHAR(20) NOT NULL DEFAULT 'REGULAR';
-- 'REGULAR' / 'DAY_LABORER_SIMPLIFIED' / 'DAY_LABORER_QUARTERLY_REPORT'
```

### EP-780. 신고 누락 알림 (MUST)

분기 마지막 달 25일 (신고 기한 1주일 전) 자동 알림:
```typescript
// 매일 cron
if (today === lastMonthOfQuarter && day === 25) {
  const pending = await getDayLaborerRecordsForQuarter(currentQuarter);
  if (pending.length > 0 && !alreadyReported(currentQuarter)) {
    await sendUrgentAlert('일용근로 지급명세서 신고 기한 1주일 전');
  }
}
```

---

## 6. 권한 (EP-790 ~ EP-799)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 일용직 명세서 (자기 것) | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| 일용직 등록 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 일용직 → 상용 전환 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 즉시 지급 승인 | ❌ | ❌ | ❌ (자동) | ✅ | ⚠️ |
| 일용근로 지급명세서 신고 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| `payroll.day_laborer` 토글 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |

---

## 7. 감사 (EP-797 ~ EP-799)

### EP-797. 필수 audit 액션

| action | 시점 |
|---|---|
| `payroll.day_laborer.registered` | 일용직 등록 |
| `payroll.day_laborer.converted_to_regular` | 상용 전환 |
| `payroll.day_laborer.auto_paid` | 자동 즉시 지급 |
| `payroll.day_laborer.quarterly_report_filed` | 분기 신고 |
| `payroll.day_laborer.quarterly_report_overdue` | 신고 기한 초과 |

---

## 8. 참조

- 게이트 토글: `feature_flags.md` § EP-900 (`payroll.day_laborer`)
- 4대보험 일반: `deduction.md`
- 즉시 지급 사이클: `payment.md` § EP-510
- 명세서 일반: `payslip.md`
- 업무 단가 (일용직 + piecework 결합): `piecework.md`
- 구체값 출처: 소득세법 §47, §134 / 국세청 일용근로 신고 안내
- 스키마 컬럼 추가: `../schemas/tables/payroll_compensation_settings.sql` (is_day_laborer / payment_cycle)
