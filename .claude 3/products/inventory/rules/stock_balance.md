# 재고 잔고 / 예약 (Stock Balance / Reservation)

> **ID 범위**: EI-200 ~ EI-299
> **주제**: (item, warehouse, location) 잔고, 예약 / 할당, 가용 계산
> **상위**: `INDEX.md`

---

## TL;DR

- **잔고 = movement 합계 (불변식)**. balance 테이블은 캐시. 정합성 깨지면 movement 합계가 진실.
- **3개 수량**: `qty` (실재고) / `reserved_qty` (주문 예약) / `allocated_qty` (배송 할당). 가용 = qty − reserved − allocated.
- **예약 (Reservation)** — 주문 확정 시 가용재고를 잡아둠. TTL / 주문상태 변경 시 자동 해제.
- **할당 (Allocation)** — 예약 → 실제 출고 직전 단계. 특정 lot / location 결정.
- **음수 차단 시점**: 예약 시점 (가장 이른 시점). 출고 시점 차단은 fallback.
- **잔고 무결성 검증** — 일/주 단위 cron 으로 movement 합계 vs balance 비교.

핵심 ID: EI-210 (모델) / EI-220 (예약) / EI-230 (할당) / EI-240 (가용 계산) / EI-250 (무결성 검증)

---

## 1. 모델 (EI-200 ~ EI-219)

### EI-200. 핵심 키 (MUST)

```sql
CREATE TABLE inventory_balances (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  location_id     UUID,                          -- NULL = 창고 전체 통합 잔고
  lot_id          UUID,                          -- LOT 추적 시 NOT NULL
  qty             NUMERIC(14, 4) NOT NULL DEFAULT 0,
  reserved_qty    NUMERIC(14, 4) NOT NULL DEFAULT 0,
  allocated_qty   NUMERIC(14, 4) NOT NULL DEFAULT 0,
  version         INTEGER NOT NULL DEFAULT 0,    -- 낙관락
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (item_id, warehouse_id, location_id, lot_id)
);
```

> **NULL handling**: PostgreSQL UNIQUE 는 NULL 을 다르게 처리. `COALESCE(location_id, '00000000-...')` 형태 또는 `WHERE` 조건 partial index 활용 권장.

### EI-210. qty 의미 (MUST)

| 컬럼 | 의미 |
|---|---|
| `qty` | 창고에 물리적으로 있는 수량 (movement 합계와 일치) |
| `reserved_qty` | 주문 / 작업지시 등으로 사전 예약된 수량 (아직 출고 X) |
| `allocated_qty` | 출고 직전 (배송 픽업) 단계, 특정 location/lot 까지 결정된 수량 |
| **가용 (계산)** | `qty − reserved_qty − allocated_qty` |

reserved + allocated ≤ qty 이어야 함:
```sql
CHECK (qty >= reserved_qty + allocated_qty OR qty = 0)
```

### EI-211. 시점별 잔고 (스냅샷)

매일 마감 시 `inventory_balance_snapshots` 에 (item, warehouse, location, lot, snapshot_date, qty) 저장. 회계 / 감사 / 시점별 조회용.

```sql
CREATE TABLE inventory_balance_snapshots (
  id              UUID PRIMARY KEY,
  -- ... 같은 키
  snapshot_date   DATE NOT NULL,
  qty             NUMERIC(14, 4) NOT NULL,
  UNIQUE (item_id, warehouse_id, location_id, lot_id, snapshot_date)
);
```

---

## 2. 예약 (Reservation) (EI-220 ~ EI-239)

### EI-220. 예약 모델 (MUST)

```sql
CREATE TABLE inventory_reservations (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  location_id     UUID,
  lot_id          UUID,
  qty             NUMERIC(14, 4) NOT NULL,
  source_type     VARCHAR(20) NOT NULL,         -- ORDER / WORK_ORDER / MANUAL
  source_id       VARCHAR(100) NOT NULL,
  status          VARCHAR(20) NOT NULL,         -- ACTIVE / RELEASED / CONSUMED / EXPIRED
  expires_at      TIMESTAMPTZ,                  -- TTL (옵션)
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  released_at     TIMESTAMPTZ,
  UNIQUE (organization_id, source_type, source_id)
);
```

### EI-221. 예약 트랜잭션 (MUST)

`ORDER_CONFIRMED` 이벤트 → 예약 생성:

```typescript
await db.$transaction(async (tx) => {
  // 1. 잔고 락 + 가용 검증 (EI-140)
  const balance = await selectForUpdate(tx, item, warehouse, location);
  const available = balance.qty - balance.reservedQty - balance.allocatedQty;
  if (available < qty) throw new InsufficientStockError({ available, requested: qty });

  // 2. reservation INSERT (멱등 — UNIQUE)
  await tx.inventoryReservation.create({ data: { ... } });

  // 3. balance.reserved_qty 증가
  await tx.inventoryBalance.update({
    where: { id: balance.id },
    data: { reservedQty: { increment: qty }, version: { increment: 1 }}
  });
});
```

### EI-225. 예약 해제 (MUST)

3가지 경로:

1. **명시 해제**: `ORDER_CANCELLED` → status = RELEASED + balance.reserved_qty 감소
2. **소비 (출고로 전환)**: 배송 출고 시 → status = CONSUMED + (allocated_qty 로 옮기거나 직접 qty 감소)
3. **TTL 만료**: cron 에서 expires_at < now() 인 ACTIVE → status = EXPIRED + balance.reserved_qty 감소

```typescript
// TTL 만료 cron (5분마다)
const expired = await db.inventoryReservation.findMany({
  where: { status: 'ACTIVE', expiresAt: { lt: new Date() }}
});
for (const r of expired) {
  await db.$transaction(async (tx) => {
    await tx.inventoryReservation.update({
      where: { id: r.id }, data: { status: 'EXPIRED', releasedAt: new Date() }
    });
    await tx.inventoryBalance.update({
      where: { /* ... */ }, data: { reservedQty: { decrement: r.qty }}
    });
  });
}
```

### EI-230. 예약 vs 할당 차이 (MUST)

| 단계 | reservation | allocation |
|---|---|---|
| 시점 | 주문 확정 시 (확정 받자마자) | 픽업 / 출고 직전 |
| 결정 수준 | item + warehouse 단위 | + location + lot 까지 |
| 수정 가능 | 가능 (해제 / 재예약) | 잠금 (변경 시 unallocate 필요) |

### EI-235. 부분 예약 / 부분 출고

- 1 reservation = 1 source_id (주문 라인). 부분 출고 → 부분 reserved → CONSUMED
- 잔량은 reservation 의 remaining_qty 별도 추적 또는 partial consume 시 새 source_id 분리

> ⚠️ 부분 처리 디자인은 사업장 정책. 단순화 위해 옵션 A 권장: **1 reservation 은 atomic** (전부 출고 또는 전부 해제, 부분 X).

---

## 3. 할당 (Allocation) (EI-240 ~ EI-249)

### EI-240. 할당 시점 (MUST)

배송 픽업 / 작업지시 발행 직전:
- reservation → allocation 전환
- balance.reserved_qty -= qty / balance.allocated_qty += qty
- 특정 location / lot 결정 (FEFO 또는 FIFO 정책)

### EI-241. 할당 시 lot 선정 (MUST)

LOT 추적 품목:
- **FEFO** (First Expiry First Out, EI-330) — 유통기한 짧은 lot 우선. 토글 `inventory.fefo_dispatch` ON 시.
- **FIFO** — 입고 일자 빠른 lot 우선 (FEFO 토글 OFF 시 기본).
- **LIFO** — 입고 일자 늦은 lot (특수 케이스, 고가 자산)

```typescript
async function pickLotForAllocation(itemId, warehouseId, qty) {
  const fefoEnabled = await isFeatureEnabled(orgId, 'inventory.fefo_dispatch');
  const orderBy = fefoEnabled ? 'expires_at asc' : 'received_at asc';
  // 가용 lot 조회 + 우선순위 정렬 + 합산하여 qty 충족
  return selectLotsToFulfill(itemId, warehouseId, qty, orderBy);
}
```

### EI-245. 할당 해제 (Unallocate) (MUST)

배송 취소 / 픽업 실패 시:
- allocation → reservation 으로 되돌리기 (balance: allocated -= / reserved += )
- 또는 reservation 도 함께 해제

---

## 4. 가용 계산 (EI-250 ~ EI-259)

### EI-250. 가용 = qty − reserved − allocated (MUST)

조회 SQL:
```sql
SELECT
  item_id, warehouse_id, location_id, lot_id,
  qty                                      AS physical,
  reserved_qty                             AS reserved,
  allocated_qty                            AS allocated,
  qty - reserved_qty - allocated_qty       AS available
FROM inventory_balances
WHERE deleted_at IS NULL;
```

### EI-251. 가용 0 미만 표시

- 표시: 0 으로 클램프 ("0 available", 음수 노출 X)
- 사후 검증 (EI-145): 음수 발견 시 알림

### EI-255. 캐시 / 빠른 조회 (SHOULD)

`inventory_balances` 자체가 이미 캐시 역할. 추가 캐시 불필요. 단, BI / 대시보드용 집계는 별도 Materialized View 권장.

---

## 5. 무결성 검증 (EI-260 ~ EI-279) — MUST

### EI-260. movement 합계 vs balance 일치 (MUST)

매일 cron — 모든 (item, warehouse, location, lot) 에 대해:
```sql
SELECT
  b.item_id, b.warehouse_id, b.location_id, b.lot_id,
  b.qty                                                AS balance_qty,
  COALESCE(SUM(m.signed_qty), 0)                       AS movement_sum,
  b.qty - COALESCE(SUM(m.signed_qty), 0)               AS diff
FROM inventory_balances b
LEFT JOIN inventory_movements m
  ON m.item_id = b.item_id
 AND m.warehouse_id = b.warehouse_id
 AND COALESCE(m.location_id, '00000000-...') = COALESCE(b.location_id, '00000000-...')
 AND m.status = 'ACTIVE'
GROUP BY b.id, b.qty
HAVING b.qty != COALESCE(SUM(m.signed_qty), 0);
```

차이 발견 시 즉시 알림 + 잠금 (해당 (item, warehouse) movement 일시 차단).

### EI-265. 자동 보정 금지 (MUST)

차이 발견 시 시스템이 임의로 balance 를 movement 합계로 덮어쓰면 안 됨 — 원인 조사 + 운영자 명시 결정 필요.

보정 절차:
1. 일시 차단
2. 운영자 조사
3. 차이 원인 movement 식별 (event 누락 / 동시성 / 외부 직접 수정 등)
4. 정정 movement INSERT (EI-150)
5. 차단 해제

### EI-270. reservation / allocation 합도 검증 (MUST)

```sql
-- balance.reserved_qty 가 active reservation 합계와 일치하는지
SELECT b.id, b.reserved_qty, COALESCE(SUM(r.qty), 0) AS reservation_sum
FROM inventory_balances b
LEFT JOIN inventory_reservations r
  ON r.item_id = b.item_id
 AND r.warehouse_id = b.warehouse_id
 AND r.status = 'ACTIVE'
GROUP BY b.id
HAVING b.reserved_qty != COALESCE(SUM(r.qty), 0);
```

---

## 6. 권한 (EI-280 ~ EI-289)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 잔고 조회 | ❌ | ✅ | ✅ | ✅ | ✅ |
| 가용 조회 (예약 / 할당 포함) | ❌ | ✅ | ✅ | ✅ | ✅ |
| 예약 생성 (자동 — 시스템) | (시스템) | | | | |
| 예약 수동 해제 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 무결성 차이 보정 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 잔고 직접 수정 (DB) | **금지 (모든 레벨)** | | | | ⚠️ Super 비상시 |

---

## 7. 감사 (EI-290 ~ EI-299)

| action | 시점 |
|---|---|
| `inventory.reservation.created` | 예약 생성 |
| `inventory.reservation.released` | 명시 해제 |
| `inventory.reservation.expired` | TTL 만료 |
| `inventory.reservation.consumed` | 출고로 전환 |
| `inventory.allocation.created` | 할당 |
| `inventory.allocation.unallocated` | 할당 해제 |
| `inventory.balance.integrity_violation` | 무결성 차이 발견 |
| `inventory.balance.integrity_corrected` | 보정 완료 |

---

## 8. 참조

- 이동 기록: `stock_movement.md` (EI-100~)
- 로트 / FEFO: `lot_tracking.md` (EI-300~)
- 위치: `warehouse.md` (EI-400~)
- 평가: `valuation.md` (EI-600~)
- 스키마: `../schemas/tables/inventory_balances.sql`, `inventory_reservations.sql`
