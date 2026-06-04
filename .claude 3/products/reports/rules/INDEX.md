# Reports Rules — 인덱스

> **Prefix**: ER-xxx
> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (D 트랙 초안)
> **참조**: `../../../rules/permissions.md`, `../../../rules/integration.md`, `../../../rules/database.md`

---

## 0. 로딩 가이드

이 인덱스 + 각 룰 파일의 TL;DR 만 우선 로드. 상세 섹션은 명시 요청 시.

---

## 1. 키워드 → 파일 트리거

| 키워드 | 파일 | TL;DR |
|---|---|---|
| 보고서 정의 / 등록 / 메타 / 쿼리 / 양식 | `report_definition.md` | ER-001~099 |
| 보고서 실행 / 생성 / 캐싱 / 결과 | `report_generation.md` | ER-100~199 |
| 자동 실행 / 스케줄 / cron / 월말 / 분기말 | `scheduling.md` | ER-200~299 |
| 이메일 발송 / 다운로드 / 배포 / API | `distribution.md` | ER-300~399 |
| 보관 / 삭제 / 감사 / 보존 기간 | `retention.md` | ER-400~499 |
| 기능 토글 / feature flag | `feature_flags.md` | ER-900~999 |

---

## 2. ID 네임스페이스

| 범위 | 주제 | 파일 | 상태 |
|---|---|---|---|
| ER-001~099 | Report Definition (정의 / 메타 / 데이터 소스) | `report_definition.md` | ✅ |
| ER-100~199 | Report Generation (실행 / 캐싱 / 결과 저장) | `report_generation.md` | ✅ |
| ER-200~299 | Scheduling (자동 실행 / cron) | `scheduling.md` | ✅ |
| ER-300~399 | Distribution (이메일 / 다운로드 / API) | `distribution.md` | ✅ |
| ER-400~499 | Retention / Audit (보관 / 삭제) | `retention.md` | ✅ |
| ER-500~599 | (예약) Custom Reports / SQL Builder | | — |
| ER-600~699 | (예약) Templates (KR 표준 양식) | | — |
| ER-700~799 | (예약) Export Formats (PDF / XLSX / CSV) | | — |
| ER-800~899 | (예약) Dashboard / 실시간 KPI | | — |
| ER-900~999 | Feature Flags | `feature_flags.md` | ✅ |

**강제 수준**: MUST / SHOULD / MAY.

---

## 3. 핵심 원칙 (모듈 전체 MUST)

1. **Reports 는 데이터 소유 X** — 다른 모듈 데이터를 **조회**만. 자체 데이터는 보고서 정의 / 실행 결과 / 스케줄 / 배포 이력만.
2. **시점별 결과 보존** — 같은 보고서를 다른 시점에 실행하면 다른 결과. 결과는 스냅샷으로 보존 (감사 / 재현 가능).
3. **권한 위임 (MUST)** — 보고서 실행 권한 = 보고서가 참조하는 모든 모듈의 조회 권한 합집합. 부족하면 거부.
4. **PII 마스킹 강제 (MUST)** — payroll 급여 / logistics 수령자 등 PII 가 포함된 보고서는 권한별 마스킹.
5. **장기 실행 보고서 = 비동기** — 임계 (예: 30초) 초과 예상 시 무조건 비동기 실행 + 완료 알림.
6. **결과 캐시는 빠르게 무효화 가능** — 모듈 데이터 보정 / 마감 차단 변경 시 영향받는 캐시 무효화.
7. **결과 보존 = 감사 / 회계 의무** — 결산 보고서는 5~10년 보존 (회계 / 세무 의무).
8. **외부 노출 보고서 = audit 필수** — 외부 메일 / API 노출 시 누가 / 언제 / 어떤 결과를 받았는지 audit.
9. **KR 법정 보고서 우선** — 4대보험 / 원천세 / K-IFRS 결산 / 부가가치세는 우선 구현.
10. **다국 / 다통화는 Phase 2+** — Phase 0 는 KRW / Asia/Seoul 단일.
11. **기능 토글** — 모든 부가 기능은 `report_feature_flags` 게이트.

---

## 4. 모듈 외부와의 약속

### 발행 이벤트 (적음 — Reports 는 주로 reactive)
| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `REPORT_GENERATED` | 보고서 생성 완료 | reportId / runId / type / period |
| `REPORT_DISTRIBUTED` | 외부 배포 완료 | runId / channel / recipients (마스킹) |
| `report.feature_flag.changed` | 토글 변경 | |

### 구독 이벤트 (캐시 무효화 트리거)
| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `payroll.payment.confirmed` | Payroll | 해당 월 급여 보고서 캐시 invalidate |
| `payroll.period.closed` | Payroll | 해당 기간 보고서 결과 finalize (수정 차단) |
| `inventory.balance.adjusted` | Inventory | 재고 평가 보고서 캐시 invalidate |
| `inventory.cycle_count.completed` | Inventory | 일자별 재고 보고서 캐시 invalidate |
| `logistics.delivery.completed` | Logistics | 배송 실적 일별 캐시 invalidate |
| `logistics.return.refunded` | Logistics | 반품률 보고서 캐시 invalidate |

상세: `../../../rules/integration.md`.

---

## 5. KR 표준 보고서 카탈로그 (Phase 0 우선)

| 코드 | 이름 | 모듈 | 주기 |
|---|---|---|---|
| `KR_PAYROLL_INSURANCE` | 4대보험 신고자료 | payroll | 월 |
| `KR_PAYROLL_WITHHOLDING` | 원천세 신고자료 | payroll | 월 |
| `KR_PAYROLL_DAY_LABORER_Q` | 일용근로자 분기 신고 | payroll | 분기 |
| `KR_PAYROLL_PAYSLIP_LIST` | 급여대장 (월별) | payroll | 월 |
| `KR_INVENTORY_VALUATION` | 재고 평가액 (K-IFRS) | inventory | 월 / 분기 / 년 |
| `KR_INVENTORY_MOVEMENT_MONTHLY` | 월별 입출고 집계 | inventory | 월 |
| `KR_LOGISTICS_DELIVERY_VOLUME` | 배송 실적 | logistics | 일 / 월 |
| `KR_LOGISTICS_RETURN_RATE` | 반품률 / 사유별 | logistics | 월 |
| `KR_FINANCIAL_CLOSING_MONTHLY` | 월결산 종합 | 통합 | 월 |

상세 정의: `report_definition.md` § 4.

---

## 6. boilerplate 코드 정합성 (Phase 1+ 예정)

| 코드 | 룰 |
|---|---|
| `business/reports/handlers/cache-invalidation.ts` | ER-150 |
| `business/reports/jobs/scheduled-runs.ts` | ER-220 |
| `business/reports/jobs/distribution-worker.ts` | ER-340 |
| `business/reports/services/permission-resolver.ts` | ER-080 |
| (기존 boilerplate) `prisma 스키마` | ER-010 |

---

## 7. Feature Flag 카탈로그 (기본값)

| feature_key | 기본값 | 설명 |
|---|---|---|
| `report.scheduled_runs` | ON | 자동 스케줄 실행 |
| `report.email_distribution` | OFF | 이메일 자동 발송 |
| `report.api_export` | OFF | 외부 API 응답 |
| `report.csv_export` | ON | CSV 다운로드 |
| `report.xlsx_export` | ON | XLSX 다운로드 |
| `report.pdf_export` | OFF | PDF 다운로드 (Phase 1+) |
| `report.kr_legal_pack` | OFF | KR 법정 보고서 묶음 (4대보험/원천세/K-IFRS) |
| `report.cache_aggressive` | ON | 적극 캐싱 (성능) |
| `report.realtime_dashboard` | OFF | 실시간 KPI (Phase 2+) |

---

## 8. 참조

- 상위: `../CLAUDE.md`
- 권한: `../../../rules/permissions.md`
- 이벤트: `../../../rules/integration.md`
- DB: `../../../rules/database.md`
- 스키마: `../schemas/INDEX.md`
- 화면: `../screens/INDEX.md`
- 데이터 소스 모듈: `../../payroll/`, `../../inventory/`, `../../logistics/`
