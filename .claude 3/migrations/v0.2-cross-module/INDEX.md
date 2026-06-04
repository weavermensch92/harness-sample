# Cross-Module Migration v0.2 — 인덱스

> **상위**: `../../CLAUDE.md`
> **버전**: v0.2 (cross-module 정합)
> **DB**: PostgreSQL 16+
> **소요**: 마이그레이션 자체 < 1분 / 룰 보강 + Phase 1 코드 정합 별도

---

## 0. 요약

4 모듈 v0.1 작업 후 발견된 cross-module 정합 갭 4종을 묶음 마이그레이션으로 처리:

1. **inventory `movement_source` 에 `RETURN` 추가** — logistics 반품 정합
2. **inventory_items 에 무게 / 부피 / 차원 컬럼** — logistics 적재 / 운임 정합
3. **payroll `work_log_source` 에 `DELIVERY` 안전 추가** — logistics → payroll 인건비 정합
4. **logistics → inventory FK 검증** — 진단 (실 추가 X)

---

## 1. 마이그레이션 카탈로그

| 번호 | 파일 | 모듈 | 영향 모듈 | 종류 |
|---|---|---|---|---|
| 001 | `001_inventory_movement_source_RETURN.sql` | inventory | logistics | ENUM 값 추가 |
| 002 | `002_inventory_items_weight_volume.sql` | inventory | logistics | 컬럼 추가 |
| 003 | `003_payroll_work_log_source_DELIVERY.sql` | payroll | logistics | ENUM 값 추가 (안전) |
| 004 | `004_logistics_inventory_FK_audit.sql` | logistics | inventory | 진단 (변경 X) |

---

## 2. 적용 순서

### 2.1 의존성

마이그레이션 자체 간 의존성 없음 — 독립 실행 가능. 단, application deploy 와의 동기 필요:

```
DB 마이그레이션 (001 → 002 → 003 → 004)
           ↓
  application 코드 deploy (구버전 호환 유지)
           ↓
  Phase 1 핸들러 / 룰 보강 활성화
```

### 2.2 PostgreSQL 트랜잭션 제약

ENUM 값 추가 (`ALTER TYPE ADD VALUE`) 는 **트랜잭션 안에서 사용 X** — 같은 트랜잭션 내 사용은 PG 에러. 분리 실행:

```bash
# 안전: 각 마이그레이션은 별도 트랜잭션 / 세션
psql -f 001_inventory_movement_source_RETURN.sql
psql -f 002_inventory_items_weight_volume.sql
psql -f 003_payroll_work_log_source_DELIVERY.sql
psql -f 004_logistics_inventory_FK_audit.sql
```

또는 Prisma 가 자동 처리 (`prisma migrate deploy`).

### 2.3 운영 환경 적용 체크리스트

- [ ] dev 검증 완료
- [ ] staging 검증 완료
- [ ] DB 백업 확인 (pre-migration snapshot)
- [ ] 마이그레이션 003 실행 후 enum 값 확인 (`SELECT enum_range(NULL::work_log_source);`)
- [ ] 마이그레이션 002 실행 후 컬럼 추가 확인 (`\d inventory_items`)
- [ ] 마이그레이션 004 진단 결과 확인 — MISSING 발견 시 별도 처리
- [ ] application 측 ENUM 값 활성 (`movement_source.RETURN`, `work_log_source.DELIVERY` 사용)
- [ ] rollback plan 검토

---

## 3. 영향 받는 룰 — 보강 매트릭스

각 마이그레이션이 영향을 미치는 룰 문서들의 보강 사항. Phase 1 코드 작업 전 룰 동기 작업 필요.

### 3.1 마이그레이션 001 — RETURN movement

| 파일 | 보강 내용 |
|---|---|
| `inventory/rules/stock_movement.md` § EI-110 | `source_type` 표에 `RETURN` 추가. 형식: `source_id = 'rtn:{return_request_id}:{return_line_id}'` |
| `inventory/rules/INDEX.md` | ENUM 카탈로그 갱신 |
| `inventory/schemas/INDEX.md` § 2 | `movement_source` ENUM 값 9개로 갱신 |
| `logistics/rules/returns.md` § EL-550 | code 예시의 `sourceType: 'RETURN'` 검증 — 정합 OK 명시 |
| `rules/integration.md` § 5.3 | MovementRecordedPayload 의 sourceType 예시에 RETURN 추가 |

### 3.2 마이그레이션 002 — weight / volume

| 파일 | 보강 내용 |
|---|---|
| `inventory/rules/item_master.md` | 신규 룰 EI-024 추가 — 물리 속성 (무게 / 부피 / 차원) |
| `inventory/rules/INDEX.md` | EI-024 추가 |
| `inventory/schemas/tables/inventory_items.sql` | weight / weight_uom / volume / volume_uom / dim_*_cm 컬럼 + CHECK |
| `logistics/rules/driver_vehicle.md` § EL-160 | item.weight / volume 검증 — NULL 처리 명시 (skip + 경고) |
| `logistics/rules/shipping_cost.md` § EL-420 | 운임 산정 — 단위 변환 / NULL 케이스 명시 |
| `logistics/screens/INDEX.md` ELS-100 (배송 생성) | 적재 시뮬레이션 UI (무게 / 부피 합계 표시) |

### 3.3 마이그레이션 003 — DELIVERY work_log_source

| 파일 | 보강 내용 |
|---|---|
| `payroll/rules/work_log.md` § EP-100 | `DELIVERY` source 명시 (이미 있음, 검증) |
| `payroll/rules/INDEX.md` | ENUM 카탈로그 — `work_log_source` 에 DELIVERY 명시 |
| `payroll/schemas/INDEX.md` | ENUM 정의 갱신 |
| `logistics/rules/delivery.md` § EL-045 | 영향 매트릭스 — DELIVERY_COMPLETED → payroll work_log 검증 |
| `rules/integration.md` § 4.1 | 시퀀스 다이어그램 — payroll WorkLog 생성 흐름 검증 |

### 3.4 마이그레이션 004 — FK 진단

진단 전용 — 변경 X. 진단 결과 MISSING 발견 시:

| FK 누락 가능성 | 처리 |
|---|---|
| `logistics_deliveries.warehouse_id` → `inventory_warehouses` | application 측 정합 검증 (현재 해당 SQL 정의 있음 — 재확인) |
| `logistics_delivery_lines.item_id` → `inventory_items` | 동일 |
| `logistics_delivery_lines.lot_id` → `inventory_lots` | optional FK (NULL 허용) |
| `logistics_routes.warehouse_id` → `inventory_warehouses` | 동일 |
| `logistics_return_requests.target_warehouse_id` → `inventory_warehouses` | 동일 |

> 모듈별 마이그레이션 적용 순서가 잘못되어 (예: logistics 먼저 → inventory 나중) FK 누락 발생 가능. Prisma 자동 순서 = 의존 그래프 따라.

---

## 4. 롤백 / 비상 대응

### 4.1 마이그레이션 001 롤백

ENUM 값 추가는 **제거 불가** (PostgreSQL 제약). 강제 롤백 필요 시:
- 새 ENUM 타입 생성 (RETURN 제외)
- 컬럼 타입 변경 (USING 캐스트)
- 기존 ENUM DROP
- (위험 — 데이터 손실 가능)

권장: 적용 전 dev / staging 검증. 운영 적용 후 롤백 X (forward fix only).

### 4.2 마이그레이션 002 롤백

```sql
-- 데이터 손실 발생. 백업 필수.
ALTER TABLE inventory_items
  DROP COLUMN IF EXISTS weight,
  DROP COLUMN IF EXISTS weight_uom,
  DROP COLUMN IF EXISTS volume,
  DROP COLUMN IF EXISTS volume_uom,
  DROP COLUMN IF EXISTS dim_length_cm,
  DROP COLUMN IF EXISTS dim_width_cm,
  DROP COLUMN IF EXISTS dim_height_cm;
```

CHECK 제약은 컬럼 DROP 시 자동 제거.

### 4.3 마이그레이션 003 롤백

001 과 동일 — ENUM 값 제거 불가. 안전 추가 (`IF NOT EXISTS`) 이므로 이미 있었으면 변경 없음.

### 4.4 마이그레이션 004 롤백

진단 전용 — 변경 X. 롤백 불필요.

---

## 5. Phase 1 코드 정합 (마이그레이션 후)

### 5.1 inventory module

- [ ] `business/inventory/handlers/movement-handler.ts`:
  - `RETURN` source_type 분기 처리 (logistics 트리거)
  - `business/logistics/handlers/return-received-handler.ts` 와 정합 (이벤트 핸들러)
- [ ] `business/inventory/types/item.ts`:
  - Item 인터페이스에 weight / volume / dimensions 추가
- [ ] `business/inventory/services/uom-service.ts` (Phase 1+):
  - 무게 / 부피 단위 변환 헬퍼

### 5.2 logistics module

- [ ] `business/logistics/services/capacity-validator.ts` (EL-160):
  - item.weight / volume + qty 합계 vs vehicle.capacity 검증
  - NULL 처리 (skip + 경고)
- [ ] `business/logistics/services/shipping-cost-service.ts` (EL-420):
  - tariff 매칭 시 weight / volume 사용
- [ ] `business/logistics/handlers/return-received-handler.ts`:
  - inventory IN movement 생성 (sourceType='RETURN')

### 5.3 payroll module

- [ ] `business/payroll/handlers/delivery-completed-handler.ts`:
  - DELIVERY_COMPLETED 이벤트 수신
  - 기사 compensation_settings 기반 amount 산출:
    - per_delivery / per_distance / per_time scheme
  - WorkLog INSERT (sourceType='DELIVERY', sourceId=deliveryId)
- [ ] `business/payroll/services/driver-compensation.ts`:
  - 기사 인건비 계산 룰 (옵션, scheme 별 분리)

---

## 6. 검증 시나리오 (마이그레이션 후)

### 6.1 RETURN movement 시나리오

```
1. logistics 반품 요청 → APPROVED → PICKED_UP → RECEIVED
2. RECEIVED 핸들러 → inventory_movements INSERT
   - direction='IN', source_type='RETURN', source_id='rtn:...'
3. inventory_balances 갱신 + 원 lot 보존
4. logistics_return_requests.status = 'RECEIVED'
```

성공 기준: movement INSERT 정상 + balance 정상 갱신 + audit 기록.

### 6.2 적재 검증 시나리오

```
1. inventory_items 에 weight=10kg, volume=0.05m3 데이터 백필
2. logistics delivery 생성 (item × 100개)
3. 배차 시 vehicle.capacity_weight=500kg 검증
   → 실 적재 = 1000kg → CapacityExceededError
4. NULL weight item → skip + 경고 로그
```

성공 기준: 검증 오류 발생 / 정상 케이스 통과 / NULL 처리 안전.

### 6.3 DELIVERY work_log 시나리오

```
1. logistics delivery 완료 → DELIVERY_COMPLETED 이벤트 발행
2. payroll delivery-completed-handler 수신
3. WorkLog INSERT (sourceType='DELIVERY', amount=기사 단가 × 1)
4. 멱등 검증 — 같은 deliveryId 재이벤트 → INSERT skip
```

성공 기준: WorkLog 정상 INSERT + 멱등 + amount 정확.

---

## 7. 누락 / Phase 1+ 결정사항

- [ ] inventory_items 의 무게 / 부피 데이터 백필 전략 (외부 import / 운영자 입력)
- [ ] UOM 변환 정책 (g ↔ kg 자동 변환 표준)
- [ ] 기사 compensation_settings 의 scheme 표준 (per_delivery / per_distance / per_time)
- [ ] WorkLog amount 정밀도 — distance_km × 단가 시 반올림 정책
- [ ] vehicle.capacity 의 NULL 처리 (검증 skip vs 거부)
- [ ] dim_*_cm 컬럼 활용 — 적재 시뮬레이션 (Phase 2+ 3D 패킹)

---

## 8. 참조

- 4-모듈 통합: `../../products/CLAUDE.md`
- DB 규약: `../../rules/database.md` § 7 (마이그레이션)
- 권한 (마이그레이션 실행): `../../rules/permissions.md` § 5 (Super 강화 audit)
- 이벤트 (DELIVERY → WorkLog 흐름): `../../rules/integration.md` § 4.1
- 영향 모듈:
  - `../../products/inventory/CLAUDE.md` § 12 (다음 단계)
  - `../../products/logistics/CLAUDE.md` § 12
  - `../../products/payroll/CLAUDE.md` § 11
