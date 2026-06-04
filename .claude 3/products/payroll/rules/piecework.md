# 업무별 단가 (Piecework)

> **ID 범위**: EP-800 ~ EP-899
> **주제**: 작업 단위 (건 / 개 / km / 상자) 단가 기반 인건비 계산
> **상위**: `INDEX.md`
> **게이트 토글**: `payroll.piecework` + `payroll.work_log_piecework_source` (`feature_flags.md` § EP-900). 둘 다 OFF 면 이 룰 비활성.

---

## TL;DR

- **scheme = `PIECEWORK`** — 시간이 아니라 **작업 수량 × 단가** 로 인건비 산정. 도급 / 건당 / 단가제.
- **task_definitions 마스터** — 사업장이 작업 종류별 단가를 사전 정의. 시점별 이력 보존.
- **work_log 의 PIECEWORK source** — 1 row = 1 작업 단위 (또는 같은 task 의 일배치 묶음).
- **amount = quantity × unit_price** — 발행자 (UI / 자동화) 가 미리 곱해서 work_log 에 즉시 확정값으로 INSERT (EP-102 동일 원칙).
- **최저임금 검증 (MUST, KR)** — piecework 도 시급 환산 ≥ 최저시급. 일급 / 주급 환산 후 검증.
- **일용직과 결합 가능** — `is_day_laborer = TRUE` + `scheme = PIECEWORK` 조합. 일용 + 단가제 (배송 / 도급).
- **task 변경 / 단가 인상** — 새 row INSERT (이력 보존). 과거 work_log 는 당시 단가로 보존.

핵심 ID: EP-810 (task 모델) / EP-820 (단가 적용) / EP-830 (work_log 변환) / EP-840 (최저임금 검증) / EP-850 (일용 결합)

---

## 1. 핵심 개념 (EP-800 ~ EP-809)

### EP-800. piecework 적용 케이스 (참고)

- **물류 / 배송**: 1건 배송 = ₩X (거리 / 무게 별 단가)
- **제조 / 포장**: 도시락 1상자 = ₩Y, 의류 1점 검수 = ₩Z
- **농업**: 수확 1박스 = ₩W
- **창고 작업**: 1팔레트 입출고 = ₩V
- **도급 / 외주**: 청소 1평 = ₩U

### EP-801. 시간제 vs 단가제 비교

| 항목 | HOURLY | PIECEWORK |
|---|---|---|
| 인건비 베이스 | 근무 시간 | 작업 수량 |
| 출퇴근 기록 | 정확히 측정 (분 단위) | 측정하나 임금 산정 베이스 X |
| 최저임금 비교 | 시급 직접 비교 | 작업 시간 × 시급 환산 후 비교 |
| 시간외 / 야간 | 가산 (§56) | 가산 적용 (시간 측정은 필요) |

> ⚠️ **piecework 도 근로기준법 적용**. "단가제니까 시간외 수당 없음" = 위법. 시간외 근무 발생 시 가산수당 별도 지급 의무.

---

## 2. task_definitions 마스터 (EP-810 ~ EP-819)

### EP-810. 모델 (MUST)

```sql
CREATE TABLE payroll_task_definitions (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  facility_id     UUID,                            -- NULL = 조직 전체
  task_code       VARCHAR(50) NOT NULL,            -- 'DELIVERY_3KM', 'BOX_PACK', 'HARVEST_BOX'
  task_name       VARCHAR(200) NOT NULL,           -- '3km 이내 배송 1건'
  unit            VARCHAR(20) NOT NULL,            -- '건' / 'km' / '상자' / '점'
  unit_price      NUMERIC(12, 0) NOT NULL,         -- KRW 정수
  effective_from  DATE NOT NULL,
  effective_to    DATE,
  notes           TEXT,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, facility_id, task_code, effective_from)
);
```

### EP-811. task_code 명명 (MUST)

- 영문 대문자 + 언더스코어
- 사업장 내 고유
- 의미 명확 (`DELIVERY_3KM` 가 `T01` 보다 좋음)
- 변경 시 새 task_code 신설 권장 (단가만 바뀌면 같은 code 의 새 effective_from row)

### EP-812. 단가 변경은 새 row (MUST)

EP-205 동일 패턴 — 단가 인상 / 인하 시:
1. 기존 row `effective_to` 갱신
2. 새 row INSERT (effective_from = 변경일)
3. 과거 work_log 는 당시 단가로 보존

UPDATE 만으로 단가 변경 금지 — 과거 시점 조회 / 분쟁 시 추적 불가.

### EP-815. 시점 조회

특정 작업일의 단가:
```sql
SELECT unit_price FROM payroll_task_definitions
WHERE organization_id = $1
  AND task_code = $2
  AND (facility_id = $3 OR facility_id IS NULL)  -- facility 우선, fallback to org
  AND effective_from <= $work_date
  AND (effective_to IS NULL OR effective_to >= $work_date)
ORDER BY facility_id NULLS LAST  -- facility 정의 우선
LIMIT 1;
```

facility 정의가 있으면 우선, 없으면 조직 전체 정의 fallback.

---

## 3. work_log 변환 (EP-820 ~ EP-839)

### EP-820. PIECEWORK source 추가 (MUST)

`work_logs.source_type` enum 에 `PIECEWORK` 추가. EP-101 매핑 보강:

| source_type | source_id 의미 |
|---|---|
| `PIECEWORK` | `pw:{task_code}:{external_ref}` (예: `pw:DELIVERY_3KM:order_12345`) |

### EP-821. 1 row 단위 (MUST)

선택지:
- **옵션 A — 작업 1건당 1 row**: 배송 100건 = work_log 100 row. source_id 가 각 작업 고유 ID.
- **옵션 B — 일배치 묶음**: 같은 사용자 / 같은 task / 같은 날 = 1 row. amount = 일배치 합계, source_id 는 묶음 식별자.

권장: **옵션 A** (이벤트 기반, 멱등). 단, 대량 (1만 건/일) 인 경우 옵션 B 일배치 (성능).

조직 정책 (`payroll.piecework_aggregation = 'PER_TASK' | 'DAILY_BATCH'`).

### EP-825. amount 산정 (MUST)

WorkLog 생성 시 amount 는 즉시 확정 (EP-102):

```typescript
async function createPieceworkWorkLog(
  userId: string, taskCode: string, externalRef: string,
  quantity: number, workDate: Date
) {
  // 1. 시점 단가 조회
  const taskDef = await getTaskDefinitionAt(orgId, facilityId, taskCode, workDate);
  if (!taskDef) throw new TaskDefinitionNotFoundError(taskCode);

  // 2. amount 확정
  const amount = Math.round(quantity * Number(taskDef.unitPrice));

  // 3. work_log INSERT
  await workLogRepo.upsertWorkLog({
    userId,
    sourceType: 'PIECEWORK',
    sourceId: `pw:${taskCode}:${externalRef}`,  // 멱등성 키
    amount,
    date: workDate,
    // ... organization / facility / team
  });
}
```

### EP-830. 멱등성 (MUST)

PIECEWORK 도 일반 work_log 멱등 (EP-110) 동일:
- `processed_events` (외부 이벤트로 생성 시) — 같은 event_id 재처리 방지
- `work_logs (source_type, source_id)` UNIQUE — DB 레벨

같은 작업이 두 번 보고되어도 1 row 만 생성됨.

### EP-832. 작업 취소 (MUST)

작업 보고 후 취소 (예: 잘못된 데이터 / 작업 무효):
- 원 work_log status = `CANCELLED` 로 전이 (ACTIVE → CANCELLED)
- 또는 AGGREGATED 후면 ADJUSTMENT row (음수)

`payroll.delivery.cancelled` 같은 외부 이벤트로 자동화 가능.

---

## 4. 최저임금 검증 (EP-840 ~ EP-849) — MUST, KR

### EP-840. 환산 검증 (MUST)

근로기준법 / 최저임금법 — piecework 도 시급 환산 ≥ 최저시급.

검증 시점:
- 작업 시간 (출퇴근 기록 / 작업 시작-종료 시각) 와 piecework 합계로 환산
- 일 단위 / 주 단위로 검증 권장

```typescript
async function validatePieceworkMinWage(
  userId: string, date: Date, dailyMinWage: number
) {
  const workLogs = await db.workLog.findMany({
    where: { userId, date, sourceType: 'PIECEWORK', status: 'ACTIVE' }
  });
  const dailyAmount = workLogs.reduce((s, w) => s + Number(w.amount), 0);

  const att = await db.payrollAttendance.findUnique({ where: { userId_date: { userId, date }}});
  const workedMinutes = att ? netMinutes(att) : 0;

  if (workedMinutes === 0) return;  // 작업 시간 미기록 — 검증 불가, 별도 알림
  const hourlyRate = (dailyAmount / workedMinutes) * 60;
  const minHourly = MIN_WAGE_KR[date.getFullYear()] ?? 10_320;  // 2026 기본

  if (hourlyRate < minHourly) {
    throw new PieceworkBelowMinWageError(
      `${userId} ${date} piecework 시급 환산 ₩${hourlyRate.toFixed(0)} < 최저시급 ₩${minHourly}`
    );
  }
}
```

### EP-841. 검증 실패 시 처리 (MUST)

- INSERT 자체는 거부하지 않음 (작업 결과는 사실)
- 대신 **부족분 보전 수당** 자동 생성 권장:
  ```typescript
  if (hourlyRate < minHourly) {
    const shortfall = (minHourly * (workedMinutes / 60)) - dailyAmount;
    await createMinWageSupplementAllowance(userId, date, shortfall);
  }
  ```
- audit 기록 + 운영자 알림

### EP-845. 작업 시간 기록 의무 (MUST)

piecework 도 출퇴근 기록 (`payroll_attendance`) 필수. 시간외 / 야간 / 휴일 가산수당 산정 + 최저임금 검증 모두 시간이 베이스.

조직이 piecework 한다고 attendance 를 끄면 안 됨. 토글로도 강제:
- `payroll.piecework` ON 인 경우, attendance 기록도 자동 ON 강제 (의존성).

---

## 5. 시간외 / 야간 / 휴일 (EP-850 ~ EP-859)

### EP-850. piecework + 가산수당 (MUST, KR)

piecework 와 시간외 / 야간 / 휴일 가산은 **양립**:

```
일급 = piecework 합계 + 가산수당
가산수당 = 통상임금 시급 × 시간외 시간 × 가산율 (50% 등)
```

여기서 통상임금 시급은:
- piecework 의 일/시간 평균 단가 환산 (당일 piecework 합계 / 작업 시간)
- 또는 `compensation_settings.base_amount` 가 있으면 그걸 사용 (혼합형)

> ⚠️ 통상임금 산정은 노동법 분쟁 핵심. 사업장 정책 명시 권장. `organization.piecework_ordinary_wage_method` 설정 ('hourly_avg' / 'fixed').

---

## 6. 일용직과 결합 (EP-860 ~ EP-869)

### EP-860. day_laborer + PIECEWORK (MUST)

가장 흔한 케이스:
- 배송 기사 (1건당 단가, 일용 고용)
- 농장 인부 (1박스 수확 단가, 일용 고용)
- 도급 청소 (1평당, 일용)

조건:
- `compensation_settings.is_day_laborer = TRUE`
- `compensation_settings.scheme = 'PIECEWORK'`
- 두 기능 토글 모두 ON: `payroll.day_laborer` + `payroll.piecework`

### EP-861. 일용 + piecework 처리 흐름

```
1. 일용 작업 발생 → PIECEWORK source work_log 생성 (amount = quantity × unit_price)
2. 일배치 / 즉시 사이클로 record DRAFT 생성 (period_type = DAILY)
3. 일용근로자 원천징수 적용 (EP-720) — 일급 기준
4. 4대보험 일용 예외 (EP-740) — 1개월 미만이면 skip
5. 즉시 지급 또는 주/월 누적 (payment_cycle)
6. 분기 마지막 달 다음 달 말일 일용근로 지급명세서 신고 (EP-770)
```

### EP-865. 일급 합산 vs 분리

같은 사람이 같은 날 여러 piecework 를 했다면 **일급 합산** 하여 일용 원천징수:
```
일급 = SUM(piecework work_logs of that day)
원천징수 = (일급 - 150,000) × 2.97%
```

`payroll_records (period_type='DAILY')` 가 합산값을 저장.

---

## 7. 권한 / 감사 (EP-880 ~ EP-899)

### EP-880. 권한 매트릭스

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| task_definitions 조회 | ❌ | ✅ (참조) | ✅ | ✅ | ✅ |
| task 신규 등록 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| task 단가 변경 | ❌ | ❌ | ✅ (반려권) | ✅ | ⚠️ |
| PIECEWORK work_log 생성 (수동) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| PIECEWORK work_log 생성 (자동, 외부 이벤트) | (시스템) | | | | |
| 최저임금 미달 보전 승인 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| `payroll.piecework` 토글 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |

### EP-890. 감사 액션

| action | 시점 |
|---|---|
| `payroll.task_definition.created` | task 신규 등록 |
| `payroll.task_definition.price_changed` | 단가 변경 (새 row) |
| `payroll.work_log.piecework_created` | PIECEWORK work_log INSERT |
| `payroll.piecework.below_min_wage_supplement` | 최저임금 보전 자동 발생 |

---

## 8. 참조

- 게이트 토글: `feature_flags.md` § EP-900 (`payroll.piecework`, `payroll.work_log_piecework_source`)
- work_log 일반: `work_log.md`
- 통상임금 / 가산수당: `salary_calc.md`, `allowance.md`
- 일용직 결합: `day_laborer.md`
- 스키마: `../schemas/tables/payroll_task_definitions.sql`
- compensation_settings 컬럼 추가: `../schemas/tables/payroll_compensation_settings.sql`
