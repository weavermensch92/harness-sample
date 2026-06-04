# Payroll Schemas — 인덱스

> **상위**: `../CLAUDE.md`
> **버전**: v0.11 (일용직 / piecework / feature flag 도입)
> **DDL 규약**: `../../../rules/database.md` § E-200~E-299

---

## 0. 적용 정책

이 디렉터리의 `.sql` 파일은 **Prisma schema.prisma 의 인간 가독 표현**. Prisma 가 정식 마이그레이션 소스. SQL 파일은:

- 도메인 의도 문서화 (코멘트 풍부)
- 비-Prisma 도구 (BI / 마이그레이션 검토) 가 참조
- 코드 리뷰 시 빠른 이해

스키마 변경은 항상:
1. Prisma `schema.prisma` 수정
2. `npx prisma migrate dev` 로 마이그레이션 생성
3. 이 디렉터리의 SQL 파일도 동기 수정 (수동, 코드 리뷰에서 강제)

CI 에서 Prisma 스키마와 SQL 파일 정합성 검증 권장 (Phase 2+).

---

## 1. 테이블 일람

| 파일 | 테이블 | 주제 | 룰 |
|---|---|---|---|
| `tables/payroll_attendance.sql` | `payroll_attendance` | 출퇴근 기록 (1일 1row) | EP-001~099 |
| `tables/payroll_work_logs.sql` | `work_logs` | 인건비 사실 기록 (멱등) | EP-100~199 |
| `tables/payroll_compensation_settings.sql` | `payroll_compensation_settings` | 사용자별 보수 설정 (이력) | EP-200~219 |
| `tables/payroll_records.sql` | `payroll_records` | 급여 계산 결과 (period_type) | EP-260~289 |
| `tables/payroll_allowances.sql` | `payroll_allowances` (+`allowance_settings`) | 수당 룰 / 적용 결과 | EP-300~349 |
| `tables/payroll_deductions.sql` | `payroll_deductions` (+`deduction_settings`, `deduction_rates`) | 공제 룰 / 적용 결과 | EP-350~399 |
| `tables/payroll_payments.sql` | `payroll_payments` | 지급 트랜잭션 (Saga) | EP-500~599 |
| **`tables/payroll_feature_flags.sql`** | **`payroll_feature_flags`** | **모듈 기능 토글** | **EP-900~999** |
| **`tables/payroll_task_definitions.sql`** | **`payroll_task_definitions`** | **업무별 단가 마스터** | **EP-810~819** |

> 명세서 (`payroll_payslips`) 는 Phase 1+ 에 별도 테이블로 추가 예정. 현재는 룰만 정의 (`rules/payslip.md`).

---

## 2. v0.11 변경 요약

### 신규 테이블 (2)
- `payroll_feature_flags` — 조직/시설/팀 스코프 기능 토글
- `payroll_task_definitions` — piecework 단가 마스터

### ENUM 확장 (2)
- `work_log_source` += `PIECEWORK`
- `compensation_scheme` += `PIECEWORK`

### 컬럼 추가
| 테이블 | 추가 컬럼 |
|---|---|
| `payroll_compensation_settings` | `is_day_laborer BOOLEAN`, `payment_cycle VARCHAR(10)` |
| `payroll_records` | `period_type VARCHAR(10)`, `period_key VARCHAR(20)`, `is_day_laborer_record BOOLEAN` |
| `payroll_payments` | `payment_cycle VARCHAR(10)` |
| `work_logs` | `piecework_meta JSONB` |

### 마이그레이션 스크립트
- `migrations/v0_11_day_laborer_piecework.sql`

---

## 3. ENUM 정의

| 타입 | 값 | 정의 위치 |
|---|---|---|
| `work_log_source` | `DELIVERY` / `MANUAL` / `ATTENDANCE` / `ADJUSTMENT` / `PIECEWORK` | `payroll_work_logs.sql` |
| `work_log_status` | `ACTIVE` / `CANCELLED` / `AGGREGATED` | `payroll_work_logs.sql` |
| `compensation_scheme` | `MONTHLY` / `DAILY` / `HOURLY` / `ANNUAL` / `PIECEWORK` | `payroll_compensation_settings.sql` |
| `record_status` | `DRAFT` / `FINALIZED` / `PAID` / `CANCELLED` | `payroll_records.sql` |
| `payment_status` | `PENDING` / `PROCESSING` / `COMPLETED` / `FAILED` / `RETRYING` | `payroll_payments.sql` |

---

## 4. 핵심 제약 (모듈 전체 불변)

| 제약 | 위치 | 의미 |
|---|---|---|
| `work_logs (source_type, source_id) UNIQUE` | `payroll_work_logs.sql` | 외부 이벤트 멱등 (EP-110) |
| `processed_events (event_id) UNIQUE` | (공통) | 이벤트 중복 처리 차단 |
| `payroll_records (user_id, period_type, period_key, version) UNIQUE` | `payroll_records.sql` | 같은 기간 같은 버전 중복 차단 (EP-260) |
| `payroll_payments (record_id, attempt_no) UNIQUE` | `payroll_payments.sql` | 시도별 명확 추적 |
| `payroll_feature_flags (organization_id, scope_type, scope_id, feature_key) UNIQUE` | `payroll_feature_flags.sql` | 토글 스코프별 1 row (EP-910) |
| `payroll_task_definitions (organization_id, facility_id, task_code, effective_from) UNIQUE` | `payroll_task_definitions.sql` | 단가 시점별 이력 (EP-812) |
| 통화 컬럼 모두 `NUMERIC(12, 0)` | 전체 | 부동소수 금지 — 한국 원화 정수 |

---

## 5. 인덱스 전략

빠른 조회 우선 인덱스:
- 사용자별 + 시점 (compensation_settings, attendance, work_logs)
- 조직 + 기간 (records, payments)
- 미처리 상태 (records.status, payments.status)
- 토글 런타임 조회 (feature_flags.organization_id + feature_key)

대량 데이터 (work_logs / attendance) 는 partial index 활용:
- `WHERE deleted_at IS NULL`
- `WHERE status = 'ACTIVE'`
- `WHERE is_day_laborer = TRUE` (소수 일용직 필터)

---

## 6. 마이그레이션 순서 (v0.11 적용 시)

1. **신규 ENUM 값**: `work_log_source += PIECEWORK`, `compensation_scheme += PIECEWORK`
   - PostgreSQL: `ALTER TYPE ... ADD VALUE` (트랜잭션 외부에서)
2. **신규 테이블**: `payroll_feature_flags`, `payroll_task_definitions`
3. **기존 테이블 ALTER**: 컬럼 추가 (NULL 허용 → 백필 → NOT NULL 강제)
4. **CHECK 제약 추가**: payment_cycle / period_type 등
5. **인덱스 추가**: 일용직 필터, period 기반
6. **검증 쿼리** 실행

상세: `migrations/v0_11_day_laborer_piecework.sql`

---

## 7. Phase 1+ 예정 테이블 (미생성)

- `payroll_payslips` — 명세서 발급 이력 (현재는 룰 EP-400~ 만)
- `payroll_feature_flag_history` — 토글 변경 상세 이력 (현재는 audit_logs 활용)
- `payroll_day_laborer_quarterly_reports` — 분기 신고 이력 (EP-770)
- `payroll_clawbacks` — 환수 트랜잭션 (현재는 음수 ADJUSTMENT 처리, EP-555)

---

## 8. 참조

- DB 규약: `../../../rules/database.md` § E-200~E-299
- 룰 카탈로그: `../rules/INDEX.md`
- 마이그레이션 파일: `migrations/v0_11_day_laborer_piecework.sql`
