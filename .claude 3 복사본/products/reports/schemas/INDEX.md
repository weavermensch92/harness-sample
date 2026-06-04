# Reports Schemas — 인덱스

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (D 트랙 초안)
> **DDL 규약**: `../../../rules/database.md`

---

## 0. 적용 정책

`payroll/inventory/logistics schemas/INDEX.md` 와 동일 — Prisma 가 정식 마이그레이션 소스.

특히 reports 는 **자체 데이터 거의 없음** — 다른 모듈을 조회하므로 cross-schema 권한 / 외래키 정합 중요.

---

## 1. 테이블 일람

| 파일 | 테이블 | 주제 | 룰 |
|---|---|---|---|
| `tables/report_definitions.sql` | `report_definitions` | 보고서 메타 / 정의 | ER-001~099 |
| `tables/report_runs.sql` | `report_runs` | 실행 인스턴스 / 결과 | ER-100~199 |
| `tables/report_schedules.sql` | `report_schedules` | 자동 실행 스케줄 | ER-200~299 |
| `tables/report_distributions.sql` | `report_distributions` | 배포 이력 (이메일 / API / Slack) | ER-300~399 |
| `tables/report_feature_flags.sql` | `report_feature_flags` | 모듈 기능 토글 | ER-900~999 |

> Phase 1+ 예정: `report_recipients_whitelist`, `report_api_endpoints`, `report_email_senders`, `report_subject_requests` (GDPR / 개인정보보호법 §35).

---

## 2. ENUM 정의

| 타입 | 값 | 위치 |
|---|---|---|
| `report_data_query_kind` | BUILTIN / SQL / API | definitions |
| `report_run_status` | PENDING / RUNNING / SUCCESS / FAILED / CANCELLED | runs |
| `report_run_trigger` | USER / SCHEDULE / API / EVENT | runs |
| `report_param_builder` | PREVIOUS_MONTH / PREVIOUS_QUARTER / PREVIOUS_DAY / PREVIOUS_WEEK / CURRENT_MONTH / CUSTOM | schedules |
| `report_dist_channel` | DOWNLOAD / EMAIL / API / SLACK | distributions |
| `report_dist_status` | PENDING / SENT / FAILED / BOUNCED | distributions |
| `report_pii_level` | MASKED / FULL | distributions |

---

## 3. 핵심 제약 (모듈 전체 불변)

| 제약 | 위치 | 의미 |
|---|---|---|
| `report_definitions (org, code, version) UNIQUE NULLS NOT DISTINCT` | definitions | 정의 버전 단일 (ER-015) |
| `report_definitions.code ~ '^[A-Z][A-Z0-9_]{2,79}$'` | definitions | 코드 형식 |
| `report_definitions` data_query_kind ↔ query_handler/text 정합 | definitions | BUILTIN/SQL/API 별 필수 컬럼 |
| `report_runs (org, definition_id, version, parameters_hash) UNIQUE` | runs | 캐시 / 멱등 키 (ER-150) |
| `report_runs` is_immutable ↔ status='SUCCESS' AND finalized_at | runs | immutable 일관성 (ER-160) |
| `report_distributions (run, channel, recipients_hash) PENDING UNIQUE` | distributions | 발송 중복 방지 (ER-380) |
| `report_schedules.wait_after_close_hours BETWEEN 0 AND 168` | schedules | 0~7일 |
| `report_schedules.cron_expression` 검증은 application | schedules | DB 검증 X |
| `report_*_feature_flags (org, scope, scope_id, feature_key) UNIQUE` | feature_flags | 토글 스코프별 1 row |

---

## 4. 외부 의존 (모듈 외부 FK)

| 외부 테이블 | 참조 컬럼 |
|---|---|
| `organizations` | 모든 테이블의 organization_id |
| `users` | runs.triggered_by_user, schedules.created_by, distributions.created_by, definitions.created_by, feature_flags.changed_by |

> 추가: payroll / inventory / logistics 데이터는 **읽기**만 — FK X, application 레벨 권한 검증 (ER-080).

---

## 5. 인덱스 전략

조회 우선:
- 활성 정의 (org, code) WHERE is_active=TRUE
- BUILTIN 정의 (is_builtin=TRUE)
- 다음 실행 (next_run_at) WHERE is_active=TRUE
- PENDING 큐 (created_at) WHERE status='PENDING'
- finalized 결과 (organization_id) WHERE is_immutable=TRUE
- 발송 실패 (organization_id, status) WHERE status IN ('FAILED', 'BOUNCED')
- 토글 런타임 (organization_id, feature_key)

---

## 6. 마이그레이션 순서 (v0.1 신규)

1. **ENUM 정의**: 7개
2. **report_definitions** (organizations 의존만)
3. **report_schedules** (definitions / organizations 의존)
4. **report_runs** (definitions / schedules / organizations 의존)
5. **report_distributions** (runs / organizations 의존)
6. **report_feature_flags** (organizations 의존만)

---

## 7. 캐시 / 무효화 흐름 (DB 외부 흐름 참고)

```
┌─ payroll.payment.confirmed ──┐
├─ inventory.balance.adjusted ──┤  ──→  report_runs.meta.cacheInvalidated = true
├─ logistics.delivery.completed ┤        (row 자체는 보존, 재실행 시 새 row)
└─ payroll.period.closed ──────┘  ──→  report_runs.is_immutable = true (해당 기간)
```

캐시 무효화는 row 삭제 X — meta 플래그만. 다음 실행 요청 시 새 run row INSERT.

---

## 8. Phase 1+ 예정 테이블 (미생성)

- `report_recipients_whitelist` — 이메일 / API endpoint 화이트리스트
- `report_api_endpoints` — 외부 API webhook (URL + secret_ref)
- `report_email_senders` — DKIM 검증된 발송자 (이메일 발송용)
- `report_subject_requests` — 데이터 주체 삭제 요청 (개인정보보호법 §35)
- `report_audit_logs` — 별도 audit (또는 공통 audit_logs 사용)

---

## 9. 참조

- 룰 카탈로그: `../rules/INDEX.md`
- DB 규약: `../../../rules/database.md`
- 외부 모듈: `../../payroll/schemas/INDEX.md`, `../../inventory/schemas/INDEX.md`, `../../logistics/schemas/INDEX.md`
