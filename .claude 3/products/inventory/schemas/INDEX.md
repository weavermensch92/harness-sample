# Inventory Schemas — 인덱스

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (D 트랙 초안)
> **DDL 규약**: `../../../rules/database.md`

---

## 0. 적용 정책

`payroll/schemas/INDEX.md` 와 동일 — Prisma 가 정식 마이그레이션 소스, 이 SQL 파일은 도메인 의도 문서화 + 비-Prisma 도구 참조.

---

## 1. 테이블 일람

| 파일 | 테이블 | 주제 | 룰 |
|---|---|---|---|
| `tables/inventory_items.sql` | `inventory_items` (+`categories`, `uom_conversions`) | 품목 마스터 / 카테고리 / 단위 변환 | EI-001~099 |
| `tables/inventory_movements.sql` | `inventory_movements` | 재고 이동 (append-only, 멱등) | EI-100~199 |
| `tables/inventory_balances.sql` | `inventory_balances` (+`snapshots`, `reservations`) | 잔고 / 일별 스냅샷 / 예약 | EI-200~299 |
| `tables/inventory_lots.sql` | `inventory_lots` (+`serials`) | 로트 / 시리얼 추적 | EI-300~399 |
| `tables/inventory_warehouses.sql` | `inventory_warehouses` (+`locations`) | 창고 / 위치 트리 | EI-400~499 |
| `tables/inventory_cycle_counts.sql` | `inventory_cycle_counts` (+`count_lines`) | 재고 실사 | EI-500~599 |
| `tables/inventory_cost_layers.sql` | `inventory_cost_layers` (+`avg_costs`) | FIFO 레이어 / 이동평균 | EI-600~699 |
| `tables/inventory_feature_flags.sql` | `inventory_feature_flags` | 모듈 기능 토글 | EI-900~999 |

---

## 2. ENUM 정의

| 타입 | 값 | 위치 |
|---|---|---|
| `item_status` | DRAFT / ACTIVE / DISCONTINUED | items |
| `item_tracking` | NONE / LOT / SERIAL | items |
| `movement_direction` | IN / OUT / TRANSFER / ADJUSTMENT | movements |
| `movement_status` | ACTIVE / CANCELLED | movements |
| `movement_source` | PURCHASE / ORDER / DELIVERY / MANUAL / COUNT_ADJUSTMENT / REVERSAL / TRANSFER_INTERNAL / EXPIRY_DISPOSAL / RETURN | movements |
| `reservation_status` | ACTIVE / RELEASED / CONSUMED / EXPIRED | balances |
| `reservation_source` | ORDER / WORK_ORDER / MANUAL | balances |
| `lot_status` | ACTIVE / QUARANTINED / EXPIRED / DISPOSED | lots |
| `serial_status` | IN_STOCK / SHIPPED / RETURNED / SCRAPPED | lots |
| `warehouse_type` | MAIN / COLD / DISTRIBUTION / RETURN / QUARANTINE | warehouses |
| `warehouse_status` | ACTIVE / INACTIVE / FROZEN | warehouses |
| `location_type` | ZONE / AISLE / RACK / BIN | warehouses |
| `cycle_count_type` | FULL / CYCLE / SPOT | cycle_counts |
| `cycle_count_status` | DRAFT / COUNTING / RECONCILING / COMPLETED / CANCELLED | cycle_counts |
| `cost_layer_status` | ACTIVE / DEPLETED | cost_layers |

---

## 3. 핵심 제약 (모듈 전체 불변)

| 제약 | 위치 | 의미 |
|---|---|---|
| `inventory_movements (org, source_type, source_id) UNIQUE` | movements | 외부 이벤트 멱등 (EI-110) |
| `inventory_balances (item, warehouse, location, lot) UNIQUE NULLS NOT DISTINCT` | balances | 잔고 키 (EI-200) |
| `inventory_balances` CHECK qty ≥ reserved + allocated | balances | 가용 무결성 (EI-210) |
| `inventory_movements` CHECK signed_qty 부호 정합 | movements | direction ↔ signed_qty (EI-121) |
| `inventory_lots (org, item, lot_no) UNIQUE` | lots | 로트 단일성 (EI-310) |
| `inventory_serials (org, item, serial_no) UNIQUE` | lots | 시리얼 단일성 (EI-320) |
| `inventory_cost_layers (in_movement_id) UNIQUE` | cost_layers | 1 IN movement = 1 레이어 (EI-610) |
| `inventory_avg_costs (item, warehouse) UNIQUE` | cost_layers | 평균 단가 단일 (EI-620) |
| `inventory_feature_flags (org, scope_type, scope_id, feature_key) UNIQUE` | feature_flags | 토글 스코프별 1 row |
| 수량 = `NUMERIC(14, 4)` | 전체 | g / ml 단위 가능 |
| 통화 = `NUMERIC(14, 0)` | 전체 | KRW 정수 |

---

## 4. 인덱스 전략

빠른 조회 우선:
- 시점별 movement (item, warehouse, occurred_at DESC)
- 활성 잔고 (organization_id, item) WHERE qty > 0
- FIFO 정렬 (item, warehouse, received_at ASC) WHERE status='ACTIVE'
- 만료 임박 lot (expires_at) WHERE status='ACTIVE'
- TTL 만료 reservation (expires_at) WHERE status='ACTIVE'
- 토글 런타임 (organization_id, feature_key)

---

## 5. 마이그레이션 순서 (v0.1 신규 적용)

1. **ENUM 정의**: 11개
2. **카테고리 / 창고 / 위치** (의존성 가장 적음)
3. **품목 / lot / serial** (categories / warehouses 의존)
4. **balances / reservations** (items / warehouses 의존)
5. **movements** (items / warehouses / lots 의존)
6. **cost_layers / avg_costs** (movements 의존)
7. **cycle_counts / count_lines** (모든 의존)
8. **feature_flags** (organizations 의존만)

---

## 6. Phase 1+ 예정 테이블 (미생성)

- `inventory_replenishment_rules` — 자동 발주 규칙 (EI-700~)
- `inventory_lot_traces` — 회수 추적 상세 (EI-355)
- `inventory_valuation_adjustments` — 평가감 (EI-645)
- `inventory_kr_tax_invoices` — KR 매입 세금계산서 연결 (EI-800~)

---

## 7. 참조

- 룰 카탈로그: `../rules/INDEX.md`
- DB 규약: `../../../rules/database.md`
- payroll 모듈 (동일 메커니즘): `../../payroll/schemas/INDEX.md`
