# 데이터베이스 규약 (Database)

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (4-모듈 통합)
> **DB**: PostgreSQL 16+
> **참조**: `./permissions.md`, `./integration.md`, 각 모듈 `schemas/INDEX.md`

---

## 0. 적용 범위

이 문서는 **payroll / inventory / logistics / reports** 4 모듈의 DDL 규약을 통합한다:

- 데이터 타입 표준
- 명명 규약 (테이블 / 컬럼 / ENUM / 인덱스 / 제약)
- 키 정책 (PK / FK / UNIQUE)
- 인덱스 전략
- 마이그레이션 운영
- 백업 / 복구
- PostgreSQL 16+ 기능 활용

각 모듈 SQL 파일은 이 문서의 규약을 준수한다.

---

## 1. PostgreSQL 버전 / 확장

### 1.1 최소 버전 (MUST)

**PostgreSQL 16+** — 다음 기능 활용:
- `UNIQUE NULLS NOT DISTINCT` (16+)
- 더 빠른 query plan / vacuum
- pg_stat_io (성능 모니터링)

### 1.2 활성화 확장 (MUST)

| 확장 | 용도 |
|---|---|
| `pgcrypto` | `gen_random_uuid()`, 해시 (SHA-256) |
| `uuid-ossp` | (선택, pgcrypto 면 충분) |
| `pg_trgm` | (선택, 검색용 trigram) |
| `btree_gin` / `btree_gist` | (선택, 복합 인덱스) |

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

### 1.3 클라이언트

- Prisma 가 정식 마이그레이션 소스
- 각 모듈의 SQL 파일은 도메인 의도 문서화 + 비-Prisma 도구 (예: dbt) 참조용
- 직접 DDL 실행은 emergency / migration 시만

---

## 2. 명명 규약 (MUST)

### 2.1 일반 원칙

- **snake_case** 통일 (테이블 / 컬럼 / ENUM / 인덱스 / 제약 모두)
- **단수 X, 복수 ○** — `inventory_items`, `logistics_deliveries` (테이블은 복수)
- **모듈 prefix 강제** — `{module}_*` (단, organizations / users / facilities 등 글로벌 마스터는 예외)

### 2.2 테이블

```
{module}_{entity}                 단일 entity
{module}_{entity}_{sub-entity}    종속 (e.g., inventory_count_lines)
{module}_{entity}_{purpose}       특수 (e.g., inventory_balance_snapshots)
```

예:
- `payroll_payments`
- `inventory_items`, `inventory_categories`, `inventory_movements`, `inventory_count_lines`
- `logistics_deliveries`, `logistics_delivery_lines`, `logistics_return_requests`
- `report_definitions`, `report_runs`

### 2.3 컬럼

| 패턴 | 의미 |
|---|---|
| `id` | PK (UUID) |
| `{table}_id` | FK (단수 + _id) |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT now() |
| `updated_at` | TIMESTAMPTZ NOT NULL DEFAULT now() |
| `deleted_at` | TIMESTAMPTZ NULL (soft delete) |
| `effective_from` / `effective_to` | DATE (시점별 이력) |
| `is_*` | BOOLEAN |
| `{noun}_count` | INTEGER (집계) |
| `{noun}_at` | TIMESTAMPTZ (이벤트 시점) |
| `{verb}_by` | UUID (FK to users.id) |
| `meta` | JSONB (확장 메타) |
| `notes` | JSONB / TEXT (감사 / 사용자 주석) |

### 2.4 ENUM

`{module}_{purpose}` 또는 `{noun}_{aspect}`:

```sql
CREATE TYPE delivery_status     AS ENUM ('DRAFT','ASSIGNED','IN_TRANSIT','DELIVERED','FAILED','CANCELLED');
CREATE TYPE movement_direction  AS ENUM ('IN','OUT','TRANSFER','ADJUSTMENT');
CREATE TYPE report_run_status   AS ENUM ('PENDING','RUNNING','SUCCESS','FAILED','CANCELLED');
```

ENUM 값은 **UPPER_SNAKE_CASE**.

### 2.5 인덱스

`idx_{table}_{purpose}` — 짧고 의도 명확:

```sql
CREATE INDEX idx_movements_item_wh_time ON inventory_movements (item_id, warehouse_id, occurred_at DESC);
CREATE INDEX idx_deliveries_org_status  ON logistics_deliveries (organization_id, status) WHERE deleted_at IS NULL;
```

### 2.6 제약 (constraints)

| 종류 | prefix |
|---|---|
| PRIMARY KEY | `pk_{table}` (Prisma 자동, 명시 X) |
| FOREIGN KEY | `fk_{table}_{column-or-target}` |
| UNIQUE | `uq_{table}_{purpose}` |
| CHECK | `ck_{table}_{purpose}` |
| NOT NULL | (제약명 X, 컬럼 정의에 표기) |

```sql
CONSTRAINT uq_movements_source UNIQUE (organization_id, source_type, source_id),
CONSTRAINT ck_movements_qty_positive CHECK (qty > 0),
CONSTRAINT fk_movements_item FOREIGN KEY (item_id) REFERENCES inventory_items(id) ON DELETE RESTRICT
```

---

## 3. 데이터 타입 표준

### 3.1 식별자

| 종류 | 타입 |
|---|---|
| 표면 PK | `UUID` (gen_random_uuid()) |
| 외부 식별자 (코드) | `VARCHAR(N)` + UNIQUE |
| 자연 키 (예: SKU) | `VARCHAR(N)` + 정규식 CHECK |

UUID 이유:
- 분산 환경 안전 (충돌 X)
- 외부 노출 시 sequence 추측 방지
- saga / outbox 등 비동기 패턴 친화

### 3.2 숫자

| 종류 | 타입 | 정밀도 |
|---|---|---|
| 통화 (KRW) | `NUMERIC(14, 0)` | 정수 (반올림) |
| 단가 (이동평균 등) | `NUMERIC(14, 4)` | 정밀도 보존 |
| 수량 | `NUMERIC(14, 4)` | g / ml / kg / m 등 |
| 거리 | `NUMERIC(10, 3)` km | 1m 단위 |
| 무게 | `NUMERIC(10, 2)` kg | 10g 단위 |
| 부피 | `NUMERIC(10, 2)` m³ | 10cc 단위 |
| 좌표 (lat/lng) | `NUMERIC(10, 7)` | 7자리 = 1cm. 운영 5자리 권장 |
| 비율 / 세율 | `NUMERIC(5, 4)` | 0.0625 = 6.25% |
| 카운트 | `INTEGER` (대부분) / `BIGINT` (대용량) | |
| 작은 enum-like (1~127) | `SMALLINT` | |

> ⚠️ `FLOAT` / `DOUBLE PRECISION` 은 통화 / 정확도 필요한 곳 **금지**. 부동소수점 오차.

### 3.3 시간

| 종류 | 타입 | 비고 |
|---|---|---|
| 시점 | `TIMESTAMPTZ` | UTC 저장, application 변환 |
| 날짜 | `DATE` | timezone-naive (생일 / effective_from 등) |
| 시각 (날짜 X) | `TIME` | (드뭄, 보통 TIMESTAMPTZ 사용) |
| 기간 | `INTERVAL` | (드뭄) |

조직 timezone 은 `Asia/Seoul` 기본. 화면 / 보고서 표시 시 변환.

### 3.4 문자열

| 종류 | 타입 |
|---|---|
| 짧은 코드 (≤ 50자) | `VARCHAR(50)` + CHECK 정규식 |
| 이름 / 라벨 | `VARCHAR(200)` |
| 주소 / 설명 | `TEXT` |
| URL / signed URL | `TEXT` |
| 정규식 검증 (예: SKU, 차량번호) | `VARCHAR(N)` + `CHECK (col ~ '...')` |

### 3.5 JSON

- 유연한 메타 / 설정: `JSONB`
- application 측 schema 검증 (Zod / ajv) 강제
- 자주 조회되는 키는 별도 컬럼으로 추출

```sql
meta JSONB,
-- 자주 쓰는 path 는 인덱스
CREATE INDEX idx_movements_meta_lot ON inventory_movements ((meta->>'lot_no'));
```

### 3.6 배열

`TEXT[]` / `UUID[]` — 유한한 작은 집합만 (보통 ≤ 10):
- `output_formats TEXT[] DEFAULT ARRAY['xlsx', 'csv']`
- `photo_urls TEXT[]`

큰 집합은 별도 테이블 (1:N).

---

## 4. 키 / 무결성 정책

### 4.1 Primary Key (MUST)

```sql
id UUID PRIMARY KEY DEFAULT gen_random_uuid()
```

모든 도메인 테이블 = UUID PK. composite PK 지양 (이벤트 / outbox / 외부 노출 시 불편).

### 4.2 자연 키 → UNIQUE

자연 키 (사용자 식별자) 는 **추가 UNIQUE** 로:

```sql
id      UUID PRIMARY KEY,                         -- 표면 PK
sku     VARCHAR(50) NOT NULL,
CONSTRAINT uq_items_org_sku UNIQUE (organization_id, sku)
```

### 4.3 멱등 키 = UNIQUE (MUST)

외부 이벤트 / 시스템 멱등 처리:

```sql
-- inventory movement
CONSTRAINT uq_movements_source UNIQUE (organization_id, source_type, source_id),
-- logistics delivery
CONSTRAINT uq_deliveries_order_line UNIQUE (organization_id, order_id, order_line_no),
-- tracking event
CONSTRAINT uq_tracking_events UNIQUE NULLS NOT DISTINCT (delivery_id, source, source_id),
-- report run cache
CONSTRAINT uq_runs_cache_key UNIQUE (organization_id, definition_id, definition_version, parameters_hash)
```

### 4.4 Foreign Key 정책 (MUST)

기본 = `ON DELETE RESTRICT` (의존 데이터 보존):

```sql
CONSTRAINT fk_movements_item FOREIGN KEY (item_id) REFERENCES inventory_items(id) ON DELETE RESTRICT
```

예외:
| 상황 | ON DELETE |
|---|---|
| 종속 lines (1:N, 부모 = 단순 묶음) | `CASCADE` (예: delivery_lines, return_lines) |
| 일반 도메인 참조 (재무 / 감사) | `RESTRICT` (default) |
| optional reference / 메타 | `SET NULL` (드뭄) |

cross-module FK 는 보수적 — 가능하면 application 레벨 정합 우선 (보고서가 다른 모듈 데이터 조회 시 FK X).

### 4.5 NULL 처리

PostgreSQL 16+ `NULLS NOT DISTINCT` 활용:

```sql
-- 균형 키 unique (location_id 또는 lot_id 가 NULL 일 수 있음)
CONSTRAINT uq_balances_key
  UNIQUE NULLS NOT DISTINCT (item_id, warehouse_id, location_id, lot_id)
```

→ NULL 도 동일 값으로 취급 → 같은 (item, wh, NULL, NULL) row 중복 차단.

### 4.6 CHECK 제약 (도메인 무결성)

비즈니스 invariant 는 DB 레벨 강제:

```sql
-- 수량 양수
CHECK (qty > 0),
-- direction ↔ signed_qty 정합
CHECK (
  (direction = 'IN'  AND signed_qty = qty) OR
  (direction = 'OUT' AND signed_qty = -qty) OR
  (direction = 'ADJUSTMENT' AND ABS(signed_qty) = qty) OR
  (direction = 'TRANSFER')
),
-- 차량번호 KR 형식
CHECK (vehicle_no ~ '^[0-9]{2,3}[가-힣][0-9]{4}$'),
-- effective 기간 정합
CHECK (effective_to IS NULL OR effective_to >= effective_from),
-- balance 가용 무결성
CHECK (qty >= reserved_qty + allocated_qty OR qty = 0)
```

복잡 invariant (cross-row, cross-table) 는 application 트랜잭션 + 트리거 (지양) 또는 별도 검증 cron.

---

## 5. 표준 컬럼 패턴

### 5.1 모든 도메인 테이블 (MUST)

```sql
id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
organization_id UUID         NOT NULL,
created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
-- soft delete (옵션)
deleted_at      TIMESTAMPTZ,

CONSTRAINT fk_{table}_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT
```

### 5.2 감사 추적 (MUST, 변경 가능 테이블)

```sql
created_by      UUID NOT NULL,                     -- FK to users.id
updated_by      UUID,                               -- 마지막 변경자 (옵션)
```

### 5.3 시점별 이력 (MUST, 변경 시 새 row)

```sql
effective_from  DATE NOT NULL,
effective_to    DATE,                               -- NULL = 진행 중
CHECK (effective_to IS NULL OR effective_to >= effective_from)
```

UPDATE 금지 — 변경 시 기존 row.effective_to 갱신 + 새 row INSERT.

### 5.4 append-only (MUST, 사실 기록)

```sql
status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',      -- ACTIVE / CANCELLED
```

UPDATE 시 status 만 변경 (CANCELLED). 데이터 자체는 보존. 정정은 새 row + REVERSAL link.

### 5.5 멀티테넌트 (MUST)

모든 도메인 row 는 `organization_id`. cross-tenant 누설 방지:
- application: actor 의 organizationId 와 매칭 검증
- DB: row-level security (RLS, 옵션, Phase 1+)

---

## 6. 인덱스 전략

### 6.1 자동 인덱스

PostgreSQL 자동:
- PRIMARY KEY → btree
- UNIQUE → btree

### 6.2 필수 인덱스 (MUST)

| 패턴 | 용도 |
|---|---|
| `(organization_id, status)` WHERE deleted_at IS NULL | 활성 row 조회 |
| `(organization_id, created_at DESC)` | 시간 역순 조회 |
| `(foreign_key)` | FK 조회 (PostgreSQL 자동 X) |
| `(time_column DESC)` | 시계열 |

### 6.3 부분 인덱스 (Partial Index)

자주 쓰는 부분 집합:

```sql
CREATE INDEX idx_runs_pending ON report_runs (created_at) WHERE status = 'PENDING';
CREATE INDEX idx_movements_active ON inventory_movements (organization_id) WHERE status = 'ACTIVE';
CREATE INDEX idx_balances_with_qty ON inventory_balances (organization_id, item_id) WHERE qty > 0;
```

### 6.4 복합 인덱스 (Composite)

조회 패턴 우선 (왼쪽부터 매칭):

```sql
-- ✅ (org, status) 또는 (org) 조회에 사용
CREATE INDEX idx_deliveries_org_status ON logistics_deliveries (organization_id, status);

-- ❌ (status) 단독 조회에는 사용 X (왼쪽 organization_id 가 없음)
```

### 6.5 GIN 인덱스 (JSONB / 배열)

```sql
-- 배열
CREATE INDEX idx_definitions_modules ON report_definitions USING GIN (source_modules);

-- JSONB 특정 키
CREATE INDEX idx_movements_meta_lot ON inventory_movements ((meta->>'lot_no'));
```

### 6.6 인덱스 모니터링

`pg_stat_user_indexes` — 사용 빈도. 사용 안 되는 인덱스 정리.

---

## 7. 마이그레이션 운영

### 7.1 정식 소스 = Prisma (MUST)

- 변경은 Prisma schema → `prisma migrate dev` → 자동 생성
- 각 모듈의 `schemas/tables/*.sql` 은 도메인 의도 문서 (수동 동기 유지)
- `schemas/migrations/` 는 명시 마이그레이션 스크립트 (예: ENUM 값 추가)

### 7.2 마이그레이션 안전 원칙 (MUST)

1. **NOT NULL 추가는 단계적** — DEFAULT 와 함께 add → backfill → NOT NULL 강제
2. **컬럼 삭제 / 이름 변경은 단계적** — copy → 새 컬럼 사용 → 구 컬럼 삭제 (3 단계)
3. **인덱스 추가는 CONCURRENTLY** — 운영 중 lock 회피
4. **ENUM 값 추가만 가능** — 삭제 / 변경 X (별도 컬럼 + migration 필요)
5. **마이그레이션 = 멱등** — 재실행 안전 (`IF NOT EXISTS`)

```sql
-- ✅ 안전
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_... ON table (...);

-- ❌ 위험 (lock)
ALTER TABLE big_table ADD COLUMN new_col VARCHAR(50) NOT NULL DEFAULT '...';
```

### 7.3 ENUM 값 추가 (MUST)

```sql
ALTER TYPE movement_source ADD VALUE IF NOT EXISTS 'RETURN' AFTER 'EXPIRY_DISPOSAL';
```

> ⚠️ ENUM 값 추가는 트랜잭션 내 X (postgres 제약). 별도 마이그레이션.

### 7.4 마이그레이션 검증 체크리스트

- [ ] dev / staging 에서 검증
- [ ] DB 백업 확인 (롤백 가능)
- [ ] 큰 테이블 (수백만 row+) 은 batch + lock-free
- [ ] index CONCURRENTLY
- [ ] downtime 최소화 (or zero-downtime 패턴)
- [ ] application 코드와 동기 (구버전 호환 또는 rolling deploy)

### 7.5 cross-module 마이그레이션

여러 모듈에 영향을 미치는 변경 (예: `movement_source` 에 `RETURN` 추가):
- 같은 PR / 같은 deploy
- 명시 순서 (DB 마이그레이션 → application deploy)
- rollback plan

---

## 8. 백업 / 복구

### 8.1 백업 정책 (MUST)

| 종류 | 빈도 | 보존 |
|---|---|---|
| Full backup | 일 1회 | 30일 |
| WAL (continuous) | 실시간 | 7일 (PITR) |
| Long-term snapshot | 월 1회 | 7년 (회계 / 세무) |

### 8.2 PITR (Point-in-Time Recovery)

WAL 보존 7일 → 임의 시점 복원 가능.

### 8.3 외부 storage 백업

`report_runs.result_*_key` 등이 가리키는 외부 storage:
- S3 / GCS lifecycle 정책 + cross-region replication
- DB 백업과 별도 — 동기 정합 검증 필요 (Phase 1+)

### 8.4 복구 RPO / RTO

| 종류 | RPO | RTO |
|---|---|---|
| WAL 기반 PITR | < 1분 | < 1시간 |
| Full backup 복원 | 24시간 | 4시간 |
| Cross-region DR | < 5분 | < 1시간 (Phase 2+) |

---

## 9. 보안

### 9.1 시크릿 (MUST)

- DB 비밀번호, API 키 = vault / secrets manager (AWS Secrets Manager / HashiCorp Vault)
- 환경변수 직접 X (개발 외)
- `report_api_endpoints.secret_ref`, `logistics_carrier_configs.secret_ref` 는 vault 참조 키만 저장

### 9.2 PII 컬럼 표시 (MUST)

PII 컬럼은 명시 코멘트:

```sql
COMMENT ON COLUMN logistics_deliveries.recipient_name
  IS 'PII (EL-070). UI 표시 시 마스킹 강제. 보존 5년.';
```

→ 코드 review / DBA 확인 시 PII 식별 가능.

### 9.3 암호화

- at-rest: Postgres 디스크 암호화 (AWS RDS / GCP Cloud SQL 기본)
- in-transit: TLS 강제 (`sslmode=require`)
- 컬럼 레벨: pgcrypto 또는 application-level (특수 PII — 주민번호 hash 등)

### 9.4 RLS (Row-Level Security, Phase 1+)

조직 격리 강화:

```sql
ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON inventory_items
  USING (organization_id = current_setting('app.current_org_id')::uuid);
```

application 측 connection 시 `SET app.current_org_id = '...'` 명시.

### 9.5 audit log 변경 금지 (MUST)

```sql
-- audit table 생성 후
REVOKE UPDATE, DELETE ON audit_logs FROM application_user;
GRANT INSERT, SELECT ON audit_logs TO application_user;
```

또는 별도 시스템 (Datadog / CloudWatch / 자체 ledger).

---

## 10. 성능 / 운영

### 10.1 큰 테이블 (수백만 row+)

- `inventory_movements`, `logistics_tracking_events`, `report_runs` 등
- 파티셔닝 (Phase 1+) — 시간 기준 (월 / 분기)
- archive (오래된 데이터를 별도 tablespace 또는 cold storage)

### 10.2 vacuum / autovacuum

- autovacuum 활성 (default)
- 큰 테이블 — 별도 튜닝 (`autovacuum_vacuum_scale_factor` 낮춤)
- VACUUM FULL 은 운영 중 lock 발생, 스케줄 (downtime / off-peak)

### 10.3 statistics / 쿼리 플랜

- 큰 테이블 변경 후 `ANALYZE`
- `EXPLAIN ANALYZE` 로 plan 확인
- 느린 쿼리 모니터링 (`pg_stat_statements`)

### 10.4 connection pooling

- pgBouncer / PgPool (transaction mode 권장)
- application 측 pool size 적절히 설정 (Prisma datasource pool_max)
- max_connections 초과 방지

---

## 11. 트랜잭션 / 격리

### 11.1 격리 수준

기본 = `READ COMMITTED`. 특수 케이스:
- 잔고 갱신 / 멱등 처리 → `SERIALIZABLE` (또는 advisory lock)
- 보고서 조회 (대량 read) → `READ ONLY` 트랜잭션

### 11.2 long-running transaction 회피 (MUST)

- 외부 API 호출은 트랜잭션 외부 (saga 패턴, `integration.md` § 1.5)
- 트랜잭션 < 5초 권장
- 큰 batch → 작은 트랜잭션으로 chunk

### 11.3 deadlock 방지

- 같은 순서로 row 잠금
- advisory lock 활용 (특정 자원 단일 작업자)

```typescript
await db.$queryRaw`SELECT pg_advisory_xact_lock(${hashCode(itemId)})`;
// 같은 item 의 movement 처리는 직렬화
```

---

## 12. JSONB 활용 가이드

### 12.1 사용 케이스 (적절)

- 가변 메타 (실험적 / 자주 바뀌는 필드)
- 외부 API raw response 저장 (디버그)
- 권한 / 정의 / 설정 — 구조 명시 (Zod 검증)
- audit metadata (변경 전후 등)

### 12.2 비사용 케이스 (지양)

- 조회 / 정렬 / 집계 자주 — 별도 컬럼이 빠름
- 관계형 / 정규화 가능 — 별도 테이블이 명확
- 큰 binary / 파일 — 외부 storage

### 12.3 Schema 검증 (MUST)

application 측 강제:
```typescript
const ParametersSchema = z.object({
  period_year: z.number().int().min(2020).max(2100),
  period_month: z.number().int().min(1).max(12)
});

const validated = ParametersSchema.parse(input);
```

DB 자체로는 검증 X (JSONB 는 자유).

---

## 13. 4-모듈 통계 / 통합 뷰

### 13.1 테이블 수 (Phase 0)

| 모듈 | 테이블 | 핵심 |
|---|---|---|
| payroll | 10 | attendance, work_logs, compensation_settings, payroll_records, allowances, deductions, payslips, payments, task_definitions, payroll_feature_flags |
| inventory | 8 | items, categories, uom_conversions, movements, balances, balance_snapshots, reservations, lots, serials, warehouses, locations, cycle_counts, count_lines, cost_layers, avg_costs, inventory_feature_flags |
| logistics | 7 (확장 시 14) | deliveries, delivery_lines, drivers, vehicles, routes, route_stops, tracking_events, pods, tariffs, region_surcharges, return_requests, return_lines, logistics_feature_flags |
| reports | 5 | report_definitions, report_runs, report_schedules, report_distributions, report_feature_flags |

### 13.2 ENUM 수 (Phase 0)

| 모듈 | ENUM |
|---|---|
| payroll | (다수, work_log_source / compensation_scheme / payment_cycle 등) |
| inventory | 16 (item_status, item_tracking, movement_*, balance_*, lot_*, warehouse_*, location_type, cycle_count_*, cost_layer_status, reservation_*) |
| logistics | 13 (delivery_*, driver_status, vehicle_status, route_*, pod_recipient_kind, return_*) |
| reports | 7 (report_data_query_kind, report_run_*, report_param_builder, report_dist_*, report_pii_level) |

### 13.3 표준 외부 의존

모든 모듈이 참조하는 글로벌 마스터:
- `organizations`
- `users`
- `facilities` (옵션)
- `teams` (payroll)
- `audit_logs` (글로벌 또는 모듈별)

→ 글로벌 마스터의 스키마는 본 문서 외부 (별도 글로벌 schema 모듈 — Phase 0 가정).

---

## 14. Phase 1+ 결정사항

- [ ] RLS (Row-Level Security) 활성화 — 멀티테넌트 강화
- [ ] 파티셔닝 — 큰 테이블 (movements / tracking / runs)
- [ ] read replica — 보고서 / 대시보드 분리
- [ ] cross-region replication — DR
- [ ] cold storage 어댑터 — archive
- [ ] 글로벌 audit ledger (immutable) — 별도 시스템
- [ ] 컬럼 레벨 암호화 — 주민번호 / 금융 정보 (Phase 2+)
- [ ] DB 변경 자동 검토 (linting) — DDL 규약 검증

---

## 15. 참조

- 권한: `./permissions.md`
- 이벤트: `./integration.md`
- 각 모듈 schema INDEX:
  - `../products/payroll/schemas/INDEX.md`
  - `../products/inventory/schemas/INDEX.md`
  - `../products/logistics/schemas/INDEX.md`
  - `../products/reports/schemas/INDEX.md`
- PostgreSQL 16 docs: https://www.postgresql.org/docs/16/
- Prisma docs: https://www.prisma.io/docs
