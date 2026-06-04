# Payroll Rules — 인덱스

> **Prefix**: EP-xxx
> **상위**: `../CLAUDE.md`
> **버전**: v0.11 (일용직 / piecework / feature flag 도입)
> **참조**: `../../../rules/permissions.md` § E-420 (마스킹), `../../../rules/integration.md` § E-810 (이벤트), `../../../rules/database.md` § E-211 (공통 컬럼)

---

## 0. 로딩 가이드 (E-901 / E-902 준수)

이 인덱스 + 각 룰 파일의 TL;DR 만 우선 로드. 상세 섹션은 명시 요청 시.

---

## 1. 키워드 → 파일 트리거

| 키워드 | 파일 | TL;DR 포함 내용 |
|---|---|---|
| 출근 / 퇴근 / 근태 / 휴게 / 결근 / 지각 | `attendance.md` | EP-001~099 요약 |
| 작업 시간 / WorkLog / 작업 기록 / 멱등 | `work_log.md` | EP-100~199 요약 |
| 급여 계산 / 시급 / 일급 / 월급 / 연봉 / 통상임금 | `salary_calc.md` | EP-200~299 요약 |
| 수당 / 야간 / 휴일 / 시간외 / 연장 | `allowance.md` | EP-300~349 요약 |
| 공제 / 4대보험 / 국민연금 / 건강보험 / 소득세 | `deduction.md` | EP-350~399 요약 |
| 명세서 / 급여명세 / payslip / 발급 | `payslip.md` | EP-400~499 요약 |
| 지급 / 이체 / 은행 / 계좌 / 결제 | `payment.md` | EP-500~599 요약 |
| **일용직 / 일용근로자 / 분리과세 / 간이지급명세서** | **`day_laborer.md`** | EP-700~799 요약 |
| **업무별 / 단가 / piecework / 도급 / 건당** | **`piecework.md`** | EP-800~899 요약 |
| **기능 토글 / feature flag / 끄기 / 켜기** | **`feature_flags.md`** | EP-900~999 요약 |

---

## 2. ID 네임스페이스

| 범위 | 주제 | 파일 | 상태 |
|---|---|---|---|
| EP-001~099 | 근태 (출퇴근 / 휴게 / 결근) | `attendance.md` | ✅ |
| EP-100~199 | 작업 시간 (WorkLog 멱등 / 상태 전이) | `work_log.md` | ✅ |
| EP-200~299 | 급여 계산 (월/일/시/연/**단가** / 통상임금) | `salary_calc.md` | ✅ (PIECEWORK 추가) |
| EP-300~349 | 수당 (야간 / 연장 / 휴일 / 식대) | `allowance.md` | ✅ |
| EP-350~399 | 공제 (4대보험 / 소득세 / 지방세 / 사내 공제) | `deduction.md` | ✅ |
| EP-400~499 | 명세서 (PDF / 발급 / 재발급 / 보관) | `payslip.md` | ✅ |
| EP-500~599 | 지급 (이체 / 결제 사이클 / 보류 / 환수) | `payment.md` | ✅ |
| EP-600~699 | (예약) 은행 / 외부 이체 게이트웨이 |  | — |
| **EP-700~799** | **일용근로자 특례 (KR)** | **`day_laborer.md`** | **✅ v0.11** |
| **EP-800~899** | **업무별 단가 (piecework)** | **`piecework.md`** | **✅ v0.11** |
| **EP-900~999** | **모듈 기능 토글** | **`feature_flags.md`** | **✅ v0.11** |

**강제 수준**: MUST / SHOULD / MAY.

---

## 3. 핵심 원칙 (모듈 전체 MUST)

1. **민감도 — 급여액은 상시 마스킹 대상** (E-420). 출력 / 응답 직전에 `maskField()` 경유.
2. **멱등 — 외부 이벤트 기반 WorkLog 는 2중 방어**. `processed_events` (eventId) + `work_logs (source_type, source_id)` unique.
3. **불변 — `AGGREGATED` 상태는 수정 금지**. 정정은 새 row.
4. **감사 — 급여 데이터 모든 read / write 는 audit_logs 기록**.
5. **트랜잭션 — 사용자 단위로 분리**.
6. **시간대 — 모든 일자는 조직 timezone 기준 (Asia/Seoul 기본)**.
7. **소수점 — 통화는 Decimal(12, 0)**.
8. **기능 토글 (v0.11)** — 모든 부가 기능은 `payroll_feature_flags` 게이트. day_laborer / piecework / firmbanking 등은 조직 단위 ON/OFF. 기본 OFF.

---

## 4. 모듈 외부와의 약속

### 발행 이벤트
| 이벤트 | 시점 |
|---|---|
| `payroll.work_log.created` | WorkLog 생성 직후 |
| `payroll.work_log.cancelled` | ACTIVE → CANCELLED |
| `payroll.record.calculated` | 집계 완료 |
| `payroll.payment.issued` | 지급 완료 |
| `payroll.payment.failed` | 이체 실패 |
| `payroll.day_laborer.auto_paid` | 일용직 즉시 지급 (v0.11) |
| `payroll.feature_flag.changed` | 토글 변경 (v0.11) |

### 구독 이벤트
| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `DELIVERY_COMPLETED` | Logistics | 기사 WorkLog 생성 (멱등) |
| `DELIVERY_CANCELLED` | Logistics | WorkLog 취소 |

---

## 5. boilerplate 코드 정합성

| 코드 | 룰 |
|---|---|
| `business/payroll/handlers/delivery-handler.ts` | EP-100, EP-110, EP-120 |
| `business/payroll/jobs/aggregate-monthly.ts` | EP-130, EP-140, EP-200 |
| `prisma WorkLog 모델` | EP-100, EP-130, EP-820 |
| `prisma ProcessedEvent / EventOutbox` | EP-110 |
| (Phase 2+) feature flag 미들웨어 | EP-920 |
| (Phase 2+) task_definitions 마스터 | EP-810 |

---

## 6. v0.11 변경 요약

### 신규 파일
- `rules/feature_flags.md` (EP-900~999)
- `rules/day_laborer.md` (EP-700~799) — KR 6.6%×45% / 4대보험 예외 / 간이명세서
- `rules/piecework.md` (EP-800~899) — task 단가 / PIECEWORK source / 최저임금 환산

### 신규 스키마
- `schemas/tables/payroll_feature_flags.sql`
- `schemas/tables/payroll_task_definitions.sql`
- `schemas/migrations/v0_11_day_laborer_piecework.sql`

### ENUM 확장
- `work_log_source` += `PIECEWORK`
- `compensation_scheme` += `PIECEWORK`

### 컬럼 추가
- `payroll_compensation_settings` += `is_day_laborer`, `payment_cycle`
- `payroll_records` += `period_type`, `period_key`, `is_day_laborer_record`
- `payroll_payments` += `payment_cycle`
- `work_logs` += `piecework_meta`

### Feature Flag 카탈로그

| feature_key | 기본값 | 설명 |
|---|---|---|
| `payroll.day_laborer` | OFF | 일용근로자 특례 |
| `payroll.piecework` | OFF | 업무별 단가 |
| `payroll.work_log_piecework_source` | OFF | work_logs PIECEWORK source 허용 |
| `payroll.weekly_holiday_strict` | ON | 주휴수당 자동 검증 |
| `payroll.under5_employee_relief` | OFF | 5인 미만 가산수당 면제 |
| `payroll.firmbanking_provider` | OFF | 펌뱅킹 어댑터 |
| `payroll.openbanking_provider` | OFF | 오픈뱅킹 어댑터 |
| `payroll.payslip_email_delivery` | ON | 명세서 이메일 발송 |
| `payroll.payslip_acknowledgment_required` | OFF | 수신 확인 강제 |
| `payroll.minimum_wage_validation` | ON | 최저임금 환산 검증 |
| `payroll.deduction_rate_yearly_alert` | ON | 요율 미입력 알림 |
| `payroll.income_tax_table_2026` | ON | 2026 간이세액표 |
| `payroll.clawback_quarter_limit` | ON | 환수 1/4 한도 (KR §43) |

---

## 6.5 v0.2 Cross-module 변경 요약

### ENUM 확장 (안전 추가)
- `work_log_source` += `DELIVERY` (logistics → payroll 정합)
  - 마이그레이션: `migrations/v0.2-cross-module/003_payroll_work_log_source_DELIVERY.sql`
  - 안전: `IF NOT EXISTS` (이미 있으면 skip)
  - 사용: `business/payroll/handlers/delivery-completed-handler.ts` (Phase 1+ 구현)

### work_log_source 전체 카탈로그 (v0.11 + v0.2)

| 값 | 의미 | 도입 |
|---|---|---|
| `ATTENDANCE` | 근태 → 시급 환산 | v0.10 |
| `MANUAL` | L3+ 직접 입력 | v0.10 |
| `ADJUSTMENT` | 마감 후 정정 | v0.10 |
| `DELIVERY` | logistics 배송 완료 → 기사 인건비 | v0.2 (안전 추가) |
| `PIECEWORK` | task 단가 기반 | v0.11 |

상세 source_id 형식: `work_log.md` § EP-101.

### 신규 핸들러 (Phase 1+ 구현 예정)
- `business/payroll/handlers/delivery-completed-handler.ts` — DELIVERY_COMPLETED 이벤트 수신 → WorkLog INSERT
- `business/payroll/services/driver-compensation.ts` — per_delivery / per_distance / per_time scheme

---

## 7. 참조

- 상위: `../CLAUDE.md`
- 권한: `../../../rules/permissions.md` § E-420
- 이벤트: `../../../rules/integration.md` § E-810
- DB: `../../../rules/database.md` § E-200
- 스키마: `../schemas/INDEX.md`
- 화면: `../screens/INDEX.md`
