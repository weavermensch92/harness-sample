# Payroll Module — CLAUDE.md

> **모듈명**: Payroll (급여 / 인건비)
> **Prefix**: EP-xxx
> **버전**: v0.11 (Phase 0)
> **상위**: `../CLAUDE.md`

---

## 1. 정체성

근태 → 작업로그 → 급여 산정 → 공제 → 명세서 → 지급 — 인건비 lifecycle 전체. KR 노동법 / 세법 / 4대보험 도메인 룰 내장.

**Phase 0 핵심 책임**:
- 출근 / 퇴근 기록 + 시간 계산 (연장 / 야간 / 휴일)
- 작업 로그 (정규 직원 hourly + 일용근로자 + piecework)
- 급여 산정 (5체계: salary / hourly / piecework / commission / day_laborer)
- 공제 (소득세 / 4대보험 / 기타)
- 급여명세서 (근로기준법 §48)
- 지급 (이체 / 즉시지급)

---

## 2. 도메인 모델

```
attendance (출퇴근) ─→ work_log (작업로그) ─→ salary_calc (급여) ─→ deduction (공제)
                                                       ↓                     ↓
                                                  allowance (수당) ─→ payslip (명세서)
                                                                            ↓
                                                                       payment (지급)
```

핵심 엔티티: `Attendance`, `WorkLog`, `CompensationSettings` (시점별 이력), `PayrollRecord`, `Allowance`, `Deduction`, `Payslip`, `Payment`, `TaskDefinition` (piecework).

---

## 3. Phase 상태

### ✅ Phase 0 (현재) — v0.11 + v0.2 (cross-module)

| 영역 | 상태 |
|---|---|
| Rules (10) | ✅ 완료 — `rules/INDEX.md` 참조 |
| Schemas (10) | ✅ 완료 — `schemas/INDEX.md` 참조 |
| Screens INDEX | ✅ 완료 — `screens/INDEX.md` |
| 일용근로자 (KR) | ✅ 완료 (EP-700~) |
| Piecework | ✅ 완료 (EP-800~) |
| Feature Flags (13) | ✅ 완료 (EP-900~) |
| **Cross-module 정합 (v0.2)** | ✅ `work_log_source` += DELIVERY (안전 추가) |
| 코드 (boilerplate) | ⚠️ 일부 — 룰 문서 대비 갭 존재 |

### ⏸ Phase 1+ (예정)

| 영역 | 비고 |
|---|---|
| Outbox publisher worker | 모든 이벤트 발행 안정화 |
| ProcessedEvent 멱등 헬퍼 | 단일 위치 검증 |
| 명세서 PDF 생성 (`rules/payslip.md` EP-450) | 이메일 / 다운로드 |
| 4대보험 신고 자동 연동 | (현재는 reports 모듈에서 자료 추출만) |
| 한국 공휴일 캘린더 | 자동 휴일 가산 |
| 명세서 다국어 | 외국인 근로자 대응 |

---

## 4. 디렉터리 구조

```
payroll/
├── CLAUDE.md                ← 이 파일
├── rules/
│   ├── INDEX.md            ← 룰 카탈로그
│   ├── attendance.md       (EP-001~099)
│   ├── work_log.md         (EP-100~199)
│   ├── salary_calc.md      (EP-200~299)
│   ├── allowance.md        (EP-300~349)
│   ├── deduction.md        (EP-350~399)
│   ├── payslip.md          (EP-400~499)
│   ├── payment.md          (EP-500~599)
│   ├── day_laborer.md      (EP-700~799) [v0.11]
│   ├── piecework.md        (EP-800~899) [v0.11]
│   └── feature_flags.md    (EP-900~999) [v0.11]
├── schemas/
│   ├── INDEX.md
│   ├── tables/             (10 테이블)
│   └── migrations/         (v0.10 → v0.11)
└── screens/
    └── INDEX.md            (EPS-xxx 화면 ID + 권한 매트릭스)
```

---

## 5. 외부 의존 (소비)

| 외부 | 용도 |
|---|---|
| `organizations` | 조직 (모든 row) |
| `facilities` | 시설 / 근무지 |
| `users` | 직원 = user (1:1) |
| `teams` | 팀 단위 권한 / 보고 |
| inventory (옵션) | piecework task 의 산출물 — `inventory.task_completed` 이벤트 (Phase 1+) |
| logistics | DELIVERY_COMPLETED → 기사 인건비 work_log INSERT |

---

## 6. 외부 발신 (이벤트)

| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `payroll.attendance.recorded` | 출퇴근 등록 | userId / facilityId / type / at |
| `payroll.work_log.confirmed` | work_log 확정 | userId / period / amount / source |
| `payroll.salary.calculated` | 월급 산정 완료 | userId / period / gross / net |
| `payroll.payment.confirmed` | 지급 완료 (이체 OK) | userId / amount / paidAt |
| `payroll.period.closed` | 마감 (수정 차단) | period / closedBy |
| `payroll.feature_flag.changed` | 토글 변경 | feature_key / scope / enabled |

소비측: reports (캐시 무효화 / immutable), 외부 회계 시스템 (Phase 1+).

---

## 7. 핵심 원칙 (요약, 상세는 `rules/INDEX.md` § 3)

1. **append-only + 정정은 새 row** — work_log / payment 변경 X
2. **시점별 이력 보존** — compensation_settings effective_from/to (UPDATE 금지)
3. **5 급여 체계 일관 처리** — salary / hourly / piecework / commission / day_laborer
4. **KR 노동법 강제** — 근로기준법 §43(임금) / §48(명세서) / §54(휴게) / §56(연장)
5. **KR 세법 강제** — 소득세법 §47(근로소득) / §134(원천징수) / §59(일용직 6%×45%)
6. **4대보험 매트릭스** — 일용직 산재만 / 정규직 4종 모두 (요건별 분기)
7. **권한 분리** — 입력자 ≠ 승인자 (payment, period_close)
8. **마감 후 immutable** — period_closed 이벤트 발행 후 수정 차단
9. **모든 부가 기능은 토글** — `payroll_feature_flags` 게이트

---

## 8. KR 법령 준수

| 영역 | 근거법 |
|---|---|
| 임금 / 휴일 / 연장 | 근로기준법 §43, §48, §54, §56 |
| 근로소득세 / 원천징수 | 소득세법 §47, §134 |
| 일용근로자 세금 | 소득세법 §59 (6% × 45%), §129 (소액부징수 ₩187K) |
| 국민연금 | 국민연금법 §6 |
| 건강보험 | 건강보험법 §6 |
| 고용보험 | 고용보험법 §10 |
| 산재보험 | 산재법 §6 |

법정 보존 기간: 급여대장 3년 (근로기준법 §42), 원천세 자료 5년 (소득세법 §164).

---

## 9. 코드 정합성 (boilerplate)

> ⚠️ Phase 0 boilerplate 와 룰 문서 사이에 갭 존재. 다음은 룰 기준 — 코드 구현 전.

| 룰 | 예상 코드 위치 |
|---|---|
| EP-010~ (attendance) | `business/payroll/handlers/attendance-handler.ts` |
| EP-130 (work_log 멱등) | `business/payroll/handlers/work-log-handler.ts` |
| EP-200 (월급 산정) | `business/payroll/services/salary-calculator.ts` |
| EP-378 (소액부징수) | `business/payroll/services/withholding-tax.ts` |
| EP-415 (명세서 발급) | `business/payroll/handlers/payslip-handler.ts` |
| EP-510 (지급 처리) | `business/payroll/handlers/payment-handler.ts` |
| Saga: 급여 → 이체 → 명세서 | `business/payroll/sagas/payroll-saga.ts` |

Phase 1 우선 구현: EP-510 (payment), EP-415 (payslip), Saga 정합.

---

## 10. 빠른 참조

- 룰 인덱스: `./rules/INDEX.md`
- 스키마 인덱스: `./schemas/INDEX.md`
- 화면 인덱스: `./screens/INDEX.md`
- 인접 모듈: `../inventory/CLAUDE.md`, `../logistics/CLAUDE.md`, `../reports/CLAUDE.md`
- 공통 룰: `../../rules/permissions.md`, `../../rules/integration.md`, `../../rules/database.md`

---

## 11. 다음 단계 (Phase 1 진입 조건)

- [x] `work_log_source` ENUM 에 `DELIVERY` 안전 추가 (logistics 정합) — **v0.2**
- [ ] `business/payroll/handlers/delivery-completed-handler.ts` — 기사 인건비 자동 생성 (DELIVERY 이벤트 수신)
- [ ] `business/payroll/services/driver-compensation.ts` — per_delivery / per_distance / per_time scheme
- [ ] EP-510 payment-handler.ts 구현 + 이체 어댑터 (KB / 신한 / 토스 등)
- [ ] EP-415 payslip-handler.ts + PDF 생성 + 이메일 발송
- [ ] Saga: 급여 산정 → 명세서 → 지급 (실패 보상 트랜잭션)
- [ ] Outbox publisher worker (이벤트 발행 안정화)
- [ ] processed_events 헬퍼 단일화
- [ ] 한국 공휴일 캘린더 연동 (Phase 1+)
- [ ] 일용근로자 분기 신고 자동 추출 (reports 모듈 정합)
