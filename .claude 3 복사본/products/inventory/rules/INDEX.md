# Inventory Rules — 인덱스

> **Prefix**: EI-xxx
> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (D 트랙 초안)
> **참조**: `../../../rules/permissions.md`, `../../../rules/integration.md`, `../../../rules/database.md`

---

## 0. 로딩 가이드 (E-901 / E-902)

이 인덱스 + 각 룰 파일의 TL;DR 만 우선 로드. 상세 섹션은 명시 요청 시.

---

## 1. 키워드 → 파일 트리거

| 키워드 | 파일 | TL;DR |
|---|---|---|
| 품목 / 상품 / SKU / 카테고리 / 단위 | `item_master.md` | EI-001~099 |
| 입고 / 출고 / 이동 / 조정 / IN/OUT/TRANSFER | `stock_movement.md` | EI-100~199 |
| 현재고 / 가용 / 예약 / 할당 / 음수재고 | `stock_balance.md` | EI-200~299 |
| 로트 / 시리얼 / 배치 / 유통기한 / 제조번호 | `lot_tracking.md` | EI-300~399 |
| 창고 / 위치 / 빈 / 존 / 구역 | `warehouse.md` | EI-400~499 |
| 실사 / 재고조사 / 차이조정 / 정기점검 | `cycle_count.md` | EI-500~599 |
| 원가 / 평가 / FIFO / 이동평균 / 평가손익 | `valuation.md` | EI-600~699 |
| 기능 토글 / feature flag | `feature_flags.md` | EI-900~999 |

---

## 2. ID 네임스페이스

| 범위 | 주제 | 파일 | 상태 |
|---|---|---|---|
| EI-001~099 | Item Master (품목 / SKU / 단위 / 카테고리) | `item_master.md` | ✅ |
| EI-100~199 | Stock Movement (입출고 / 멱등 / 상태) | `stock_movement.md` | ✅ |
| EI-200~299 | Stock Balance / Reservation | `stock_balance.md` | ✅ |
| EI-300~399 | Lot / Batch / Expiry (KR 식품/의약품) | `lot_tracking.md` | ✅ |
| EI-400~499 | Warehouse / Location | `warehouse.md` | ✅ |
| EI-500~599 | Cycle Count (재고 실사) | `cycle_count.md` | ✅ |
| EI-600~699 | Valuation (원가 평가) | `valuation.md` | ✅ |
| EI-700~799 | (예약) Replenishment / 자동 발주 |  | — |
| EI-800~899 | (예약) KR 세금계산서 / 매입 정합 |  | — |
| EI-900~999 | Feature Flags | `feature_flags.md` | ✅ |

**강제 수준**: MUST / SHOULD / MAY.

---

## 3. 핵심 원칙 (모듈 전체 MUST)

1. **사실 기록 — Movement 는 append-only**. 한번 INSERT 된 movement 는 UPDATE / DELETE 금지. 정정은 역(逆) movement 새 row.
2. **잔고 = 이동 합계 (불변식)**. balance 테이블은 캐시 / 가속용. 정합성 깨지면 movement 합계가 진실.
3. **음수 재고 방지 (MUST)**. OUT / TRANSFER 시점에 가용재고 ≥ 요청수량 검증. 동시성 안전 (행 락 / 낙관락).
4. **멱등 — 외부 이벤트 기반 movement 는 2중 방어**. processed_events + movements (source_type, source_id) UNIQUE.
5. **트랜잭션 — movement INSERT + balance UPDATE 는 단일 트랜잭션**. Saga 가 아닌 DB 트랜잭션 (단일 모듈 내 정합).
6. **로트 추적 의무 — 식품 / 의약품 / 화장품 / 위험물**. KR 규제 영역은 lot_id 필수. 일반 자재는 옵션.
7. **단위 일관성 — 모든 수량은 base_uom 기준 저장**. 표시 단위 (UI) 와 분리. 변환 오차 방지.
8. **유통기한 우선 출고 (FEFO)** — 로트 추적 시. FIFO 보다 우선.
9. **시간대 — 모든 일자는 조직 timezone 기준 (Asia/Seoul 기본)**.
10. **소수점 — 수량은 NUMERIC(14, 4)** (g / ml 단위 가능). 통화는 NUMERIC(14, 0) (KRW 정수).
11. **기능 토글** — 모든 부가 기능은 `inventory_feature_flags` 게이트. 기본 OFF.

---

## 4. 모듈 외부와의 약속

### 발행 이벤트
| 이벤트 | 시점 | 페이로드 핵심 |
|---|---|---|
| `inventory.movement.recorded` | Movement INSERT 직후 | itemId / locationId / qty / direction / sourceType |
| `inventory.balance.changed` | Balance 변경 직후 | itemId / locationId / before / after |
| `inventory.stock.reserved` | 예약 생성 | itemId / locationId / qty / reservationId |
| `inventory.stock.released` | 예약 해제 | reservationId / qty |
| `inventory.lot.expired` | 유통기한 도래 (배치 감지) | lotId / itemId / qty |
| `inventory.cycle_count.completed` | 실사 완료 + 차이 조정 | warehouseId / discrepancyCount |
| `inventory.feature_flag.changed` | 토글 변경 | scope / featureKey |

### 구독 이벤트
| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `ORDER_CONFIRMED` | (외부) | 재고 예약 (allocation) |
| `ORDER_CANCELLED` | (외부) | 예약 해제 |
| `DELIVERY_DISPATCHED` | Logistics | OUT movement 생성 (예약 → 실 출고) |
| `PURCHASE_RECEIVED` | (외부) | IN movement 생성 |

상세: `../../../rules/integration.md`.

---

## 4.5 ENUM 카탈로그 (모듈 내 정의)

| ENUM | 값 | 갱신 |
|---|---|---|
| `item_status` | DRAFT / ACTIVE / DISCONTINUED | v0.1 |
| `item_tracking` | NONE / LOT / SERIAL | v0.1 |
| `movement_direction` | IN / OUT / TRANSFER / ADJUSTMENT | v0.1 |
| `movement_status` | ACTIVE / CANCELLED | v0.1 |
| `movement_source` | PURCHASE / ORDER / DELIVERY / MANUAL / COUNT_ADJUSTMENT / REVERSAL / TRANSFER_INTERNAL / EXPIRY_DISPOSAL / **RETURN** | v0.2 (RETURN 추가) |
| `reservation_status` | ACTIVE / RELEASED / CONSUMED / EXPIRED | v0.1 |
| `reservation_source` | ORDER / WORK_ORDER / MANUAL | v0.1 |
| `lot_status` | ACTIVE / QUARANTINED / EXPIRED / DISPOSED | v0.1 |
| `serial_status` | IN_STOCK / SHIPPED / RETURNED / SCRAPPED | v0.1 |
| `warehouse_type` | MAIN / COLD / DISTRIBUTION / RETURN / QUARANTINE | v0.1 |
| `warehouse_status` | ACTIVE / INACTIVE / FROZEN | v0.1 |
| `location_type` | ZONE / AISLE / RACK / BIN | v0.1 |
| `cycle_count_type` | FULL / CYCLE / SPOT | v0.1 |
| `cycle_count_status` | DRAFT / COUNTING / RECONCILING / COMPLETED / CANCELLED | v0.1 |
| `cost_layer_status` | ACTIVE / DEPLETED | v0.1 |

상세 정의: `../schemas/INDEX.md` § 2.

---

## 5. boilerplate 코드 정합성 (Phase 1+ 예정)

| 코드 | 룰 |
|---|---|
| (Phase 1+) `business/inventory/handlers/order-handler.ts` | EI-100, EI-110, EI-200 |
| (Phase 1+) `business/inventory/handlers/delivery-handler.ts` | EI-100, EI-150 |
| (Phase 1+) `business/inventory/jobs/expiry-watch.ts` | EI-330 |
| (Phase 1+) `business/inventory/jobs/cycle-count.ts` | EI-500 |

---

## 6. Feature Flag 카탈로그 (기본값)

| feature_key | 기본값 | 설명 |
|---|---|---|
| `inventory.lot_tracking` | OFF | 로트 / 유통기한 추적 |
| `inventory.serial_tracking` | OFF | 시리얼 단위 추적 (가전 / 의료기기) |
| `inventory.multi_warehouse` | OFF | 다중 창고 운영 (단일 창고 시 OFF) |
| `inventory.location_bin` | OFF | 창고 내 빈 단위 위치 관리 |
| `inventory.reservation` | ON | 예약 / 할당 (음수재고 방지의 베이스) |
| `inventory.fefo_dispatch` | OFF | 유통기한 우선 출고 (lot_tracking 의존) |
| `inventory.valuation_fifo` | ON | FIFO 원가 평가 |
| `inventory.valuation_moving_avg` | OFF | 이동평균 원가 평가 (둘 중 택 1) |
| `inventory.cycle_count` | ON | 정기 실사 |
| `inventory.negative_stock_block` | ON | 음수 재고 INSERT 차단 |
| `inventory.expiry_block_ship` | ON | 유통기한 만료 출고 차단 |
| `inventory.kr_tax_invoice_link` | OFF | 매입 movement 와 세금계산서 연결 (Phase 1+) |

---

## 7. 참조

- 상위: `../CLAUDE.md`
- 권한: `../../../rules/permissions.md`
- 이벤트: `../../../rules/integration.md`
- DB 규약: `../../../rules/database.md`
- 스키마: `../schemas/INDEX.md`
- 화면: `../screens/INDEX.md`
