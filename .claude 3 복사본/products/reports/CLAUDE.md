# Reports Module — CLAUDE.md

> **모듈명**: Reports (보고서 / 집계 / 배포)
> **Prefix**: ER-xxx
> **버전**: v0.1 (Phase 0)
> **상위**: `../CLAUDE.md`

---

## 1. 정체성

다른 모듈 데이터를 **조회 / 집계 / 보존 / 배포** — 자체 데이터 X. KR 법정 보고서 (4대보험 / 원천세 / K-IFRS / 회계장부) 우선 지원.

**Phase 0 핵심 책임**:
- 보고서 정의 / 메타 (BUILTIN / SQL / API 3종)
- 실행 lifecycle (PENDING → RUNNING → SUCCESS / FAILED / CANCELLED)
- 자동 스케줄 (cron, Asia/Seoul, 마감 대기)
- 결과 캐싱 + 모듈 이벤트 기반 무효화
- 권한 위임 (모든 모듈 권한 합집합)
- PII 분리 결과 (마스킹 / 풀 두 파일)
- 배포 (다운로드 / 이메일 / API / Slack)
- 보존 / 자동 삭제 (KR 법정 5~10년)

---

## 2. 도메인 모델

```
report_definition (메타)
   ↓ (실행)
report_run (인스턴스, 캐시 키 UNIQUE)
   ├─ result_masked + result_full (외부 storage)
   └─ report_distribution (배포 이력)

report_schedule (cron) ─→ trigger ─→ report_run

[외부 모듈 이벤트] ─→ 캐시 무효화 / immutable 마킹
```

핵심 엔티티: `ReportDefinition`, `ReportRun`, `ReportSchedule`, `ReportDistribution`. (자체 운영 데이터만, 보고서 결과 본문은 외부 storage).

---

## 3. Phase 상태

### ✅ Phase 0 (현재) — v0.1

| 영역 | 상태 |
|---|---|
| Rules (6) + INDEX | ✅ 완료 |
| Schemas (5 테이블) | ✅ 완료 — 7개 ENUM |
| Screens INDEX (ERS-xxx) | ✅ 완료 |
| KR 법정 보고서 카탈로그 (9종) | ✅ 룰 정의 (BUILTIN handler 는 Phase 1+) |
| 권한 위임 (AND 합집합) | ✅ 룰 정의 |
| PII 분리 결과 | ✅ 룰 정의 |
| Feature Flags (9) | ✅ 완료 |
| 코드 (boilerplate) | ⚠️ Phase 1+ |

### ⏸ Phase 1+ (예정)

| 영역 | 비고 |
|---|---|
| KR 법정 BUILTIN handler 9종 | 4대보험 / 원천세 / K-IFRS / 결산 등 |
| `report_recipients_whitelist` | 화이트리스트 |
| `report_api_endpoints` | 외부 webhook (URL + secret) |
| `report_email_senders` | DKIM 검증된 발송자 |
| Email / API / Slack 어댑터 | 발송 구현 |
| PDF 생성 (Phase 1+) | xlsx 우선, pdf 는 후순위 |
| Custom SQL builder (Phase 2+) | 비기술 사용자용 |
| 실시간 dashboard (Phase 2+) | 실시간 KPI |
| 데이터 주체 요청 처리 (Phase 1+) | 개인정보보호법 §35 |

---

## 4. 디렉터리 구조

```
reports/
├── CLAUDE.md
├── rules/
│   ├── INDEX.md
│   ├── report_definition.md  (ER-001~099)
│   ├── report_generation.md  (ER-100~199)
│   ├── scheduling.md         (ER-200~299)
│   ├── distribution.md       (ER-300~399)
│   ├── retention.md          (ER-400~499)
│   └── feature_flags.md      (ER-900~999)
├── schemas/
│   ├── INDEX.md
│   └── tables/               (5 SQL 파일)
└── screens/
    └── INDEX.md              (ERS-xxx)
```

---

## 5. 외부 의존 (소비)

| 외부 | 용도 |
|---|---|
| `organizations` | 조직 |
| `users` | 트리거 / 생성자 |
| **payroll / inventory / logistics 데이터** | 조회 (read-only, application 권한) |
| 외부 storage (S3 / GCS / Supabase Storage) | 결과 파일 보관 |
| 외부 큐 (BullMQ / SQS) | 비동기 실행 |

> 외부 모듈 데이터는 **FK 없음** — 권한 검증은 application 레벨 (`required_permissions` 메타).

---

## 6. 외부 발신 (이벤트)

| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `report.run.started` | 실행 시작 | runId / definitionCode / triggeredBy |
| `report.run.succeeded` | 결과 생성 완료 | runId / rowCount / fileSize |
| `report.run.failed` | 실패 | runId / error |
| `report.run.finalized` | period_closed 후 immutable | runId / period |
| `report.distribution.sent` | 배포 완료 | distributionId / channel / piiLevel |
| `report.feature_flag.changed` | 토글 변경 | feature_key |

소비측: 운영 알림 / 외부 모니터링.

---

## 7. 외부 구독 (캐시 무효화 / immutable 마킹)

| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `payroll.payment.confirmed` | payroll | 해당 월 보고서 캐시 invalidate |
| `payroll.period.closed` | payroll | 해당 기간 SUCCESS run 모두 immutable=true |
| `inventory.balance.adjusted` | inventory | 재고 평가 보고서 캐시 invalidate |
| `inventory.cycle_count.completed` | inventory | 일자별 재고 보고서 캐시 invalidate |
| `inventory.month_closed` | inventory | 해당 기간 immutable |
| `logistics.delivery.completed` | logistics | 배송 실적 일별 캐시 invalidate |
| `logistics.return.refunded` | logistics | 반품률 캐시 invalidate |

---

## 8. 핵심 원칙 (요약, 상세 `rules/INDEX.md` § 3)

1. **데이터 소유 X** — 다른 모듈을 조회만. 자체는 정의 / 실행 / 스케줄 / 배포 메타.
2. **시점별 결과 보존** — 같은 보고서 다른 시점 = 다른 결과. 스냅샷 보존.
3. **권한 위임 (AND 합집합)** — 보고서 = 모든 데이터 소스 모듈의 조회 권한 합.
4. **PII 마스킹 강제** — 권한별 마스킹 / 풀 결과 분리. 외부 발송은 기본 마스킹.
5. **장기 실행 = 비동기** — 30s 초과 예상 시 큐 등록 + 완료 알림.
6. **immutable run 영구** — period_closed 후 수정 / 재생성 X (Super 강제만).
7. **결과 보존 = 회계 / 세무 의무** — 5~10년 (KR 법정).
8. **외부 노출 = audit + 화이트리스트** — 이메일 / API / Slack 모두.
9. **KR 법정 보고서 우선 (BUILTIN)** — 변동성 적고 정합성 중요.

---

## 9. KR 법정 보존 / 보고서

### 보존 기간 매트릭스

| 종류 | 근거법 | 기간 |
|---|---|---|
| 급여대장 / 임금명세서 | 근로기준법 §42 | 3년 |
| 4대보험 신고 | 국민연금법 / 건강보험법 등 | 3년 |
| 원천세 / 지급명세서 | 소득세법 §164 | 5년 |
| 부가가치세 자료 | 부가가치세법 §32 | 5년 |
| 거래 기록 (전자상거래) | 전자상거래법 §6 ③ | 5년 |
| 회계장부 / 재무제표 | 상법 §33 / K-IFRS | 10년 |

### KR 법정 보고서 카탈로그

| 코드 | 이름 | 모듈 |
|---|---|---|
| KR_PAYROLL_INSURANCE | 4대보험 신고자료 | payroll |
| KR_PAYROLL_WITHHOLDING | 원천세 신고자료 | payroll |
| KR_PAYROLL_DAY_LABORER_Q | 일용근로자 분기 신고 | payroll |
| KR_PAYROLL_PAYSLIP_LIST | 급여대장 | payroll |
| KR_INVENTORY_VALUATION | 재고 평가 (K-IFRS) | inventory |
| KR_INVENTORY_MOVEMENT_MONTHLY | 월별 입출고 | inventory |
| KR_LOGISTICS_DELIVERY_VOLUME | 배송 실적 | logistics |
| KR_LOGISTICS_RETURN_RATE | 반품률 | logistics |
| KR_FINANCIAL_CLOSING_MONTHLY | 월결산 (통합) | 통합 |

---

## 10. 코드 정합성 (boilerplate)

| 룰 | 예상 코드 위치 |
|---|---|
| ER-115 (실행 시작) | `business/reports/services/run-service.ts` |
| ER-130 (비동기 큐) | `business/reports/jobs/report-worker.ts` |
| ER-150 (캐시 hit / invalidate) | `business/reports/services/cache-service.ts` |
| ER-153 (이벤트 핸들러) | `business/reports/handlers/cache-invalidation.ts` |
| ER-160 (period_closed → immutable) | `business/reports/handlers/finalize-handler.ts` |
| ER-220 (cron polling) | `business/reports/jobs/scheduled-runs.ts` |
| ER-340 (API webhook) | `business/reports/services/api-distribution.ts` |
| ER-440 (purge cron) | `business/reports/jobs/retention-purge.ts` |
| KR BUILTIN handler 9종 | `business/reports/builtin/kr-payroll-insurance.ts` 등 |

Phase 1 우선 구현: ER-115 + ER-130 (실행 큐), ER-153 (캐시 무효화), KR_PAYROLL_INSURANCE BUILTIN.

---

## 11. 빠른 참조

- 룰: `./rules/INDEX.md`
- 스키마: `./schemas/INDEX.md`
- 화면: `./screens/INDEX.md`
- 인접 모듈: `../payroll/CLAUDE.md`, `../inventory/CLAUDE.md`, `../logistics/CLAUDE.md`
- 공통 룰: `../../rules/permissions.md`, `../../rules/integration.md`, `../../rules/database.md`

---

## 12. 다음 단계 (Phase 1 진입 조건)

- [ ] ER-115 run-service.ts (실행 + 캐시 hit 검증)
- [ ] ER-130 report-worker.ts (큐 + 비동기 처리)
- [ ] ER-153 cache-invalidation handler (모듈 이벤트 수신)
- [ ] ER-160 finalize-handler (period_closed → immutable)
- [ ] ER-220 scheduled-runs cron + 마감 대기 검증
- [ ] ER-440 retention-purge cron (file 삭제, row 보존)
- [ ] KR_PAYROLL_INSURANCE BUILTIN handler (4대보험)
- [ ] KR_PAYROLL_WITHHOLDING BUILTIN handler (원천세)
- [ ] KR_INVENTORY_VALUATION BUILTIN handler (K-IFRS)
- [ ] Phase 1+ 테이블: whitelist / api_endpoints / email_senders
- [ ] 외부 storage 어댑터 (S3 / GCS) — signed URL 발급
- [ ] 큐 시스템 선택 + 구현 (BullMQ / SQS / DB-based)
