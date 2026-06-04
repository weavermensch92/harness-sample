# 재고 이동 (Stock Movement)

> **ID 범위**: EI-100 ~ EI-199
> **주제**: 입고 / 출고 / 이동 / 조정 트랜잭션 (사실 기록)
> **상위**: `INDEX.md`

---

## TL;DR

- **Append-only**. INSERT 후 UPDATE / DELETE 금지. 정정은 역(逆) movement 새 row.
- **direction**: `IN` (입고) / `OUT` (출고) / `TRANSFER` (이동) / `ADJUSTMENT` (조정).
- **멱등 (MUST)** — 외부 이벤트 기반은 `processed_events` (event_id) + movements (source_type, source_id) UNIQUE 2중 방어.
- **트랜잭션 — INSERT + balance UPDATE 단일 DB 트랜잭션**. Saga X (단일 모듈 내).
- **음수 재고 차단** — OUT / TRANSFER 시 `available_qty ≥ 요청 수량` 검증 (행 락 또는 낙관락).
- **로트 / 시리얼 시 lot_id 필수** — `tracking_mode != NONE` 인 품목 movement 는 lot_id NOT NULL.
- **단위 — 항상 base_uom**. 표시 단위는 호출자가 변환 후 INSERT.
- **상태 = ACTIVE / CANCELLED**. CANCELLED 은 잔고 영향 없음 (역 movement 처리).

핵심 ID: EI-110 (멱등) / EI-120 (direction) / EI-130 (트랜잭션) / EI-140 (음수 차단) / EI-150 (정정)

---

## 1. 모델 (EI-100 ~ EI-109)

### EI-100. 핵심 필드 (MUST)

```sql
CREATE TABLE inventory_movements (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  facility_id     UUID,
  warehouse_id    UUID NOT NULL,
  location_id     UUID,                              -- 빈/존 단위 (옵션)
  item_id         UUID NOT NULL,
  lot_id          UUID,                              -- LOT/SERIAL 모드 시 필수

  direction       VARCHAR(10) NOT NULL,              -- IN/OUT/TRANSFER/ADJUSTMENT
  qty             NUMERIC(14, 4) NOT NULL,           -- base_uom 단위, 항상 양수

  -- TRANSFER 전용 (목적지)
  to_warehouse_id UUID,
  to_location_id  UUID,

  -- 외부 출처 (멱등)
  source_type     VARCHAR(20) NOT NULL,              -- PURCHASE/ORDER/DELIVERY/MANUAL/COUNT_ADJUSTMENT/REVERSAL
  source_id       VARCHAR(100) NOT NULL,             -- 외부 시스템 ID 또는 자연 키

  -- 상태
  status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE/CANCELLED

  -- 평가 단가 (스냅샷)
  unit_cost       NUMERIC(14, 0),                    -- 평가용 단가 (원/base_uom)
  total_cost      NUMERIC(14, 0),                    -- qty × unit_cost

  -- 메타
  reason          TEXT,
  reference       TEXT,                              -- 외부 문서 번호 등
  meta            JSONB,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  occurred_at     TIMESTAMPTZ NOT NULL,              -- 실제 발생 시점

  UNIQUE (organization_id, source_type, source_id)   -- 멱등 (EI-110)
);
```

### EI-101. source_type 카탈로그 (MUST)

| source_type | 의미 | source_id 형식 |
|---|---|---|
| `PURCHASE` | 매입 입고 | `po:{purchase_order_id}:{line}` |
| `ORDER` | 판매주문 (예약 시) | `ord:{order_id}:{line}` |
| `DELIVERY` | 출고 (배송) | `dlv:{delivery_id}` |
| `MANUAL` | 수동 입력 (idempotency key) | `man:{user_id}:{ulid}` |
| `COUNT_ADJUSTMENT` | 실사 차이 조정 | `cnt:{cycle_count_id}:{item_id}` |
| `REVERSAL` | 역 movement (정정, EI-150) | `rev:{original_movement_id}` |
| `TRANSFER_INTERNAL` | 창고/위치 간 이동 | `tr:{transfer_request_id}` |
| `EXPIRY_DISPOSAL` | 유통기한 만료 폐기 | `exp:{lot_id}:{date}` |
| `RETURN` | 반품 입고 (logistics 정합) | `rtn:{return_request_id}:{return_line_id}` |

---

## 2. 멱등 (EI-110 ~ EI-119) — MUST

### EI-110. 2중 방어

외부 이벤트 (DELIVERY_DISPATCHED 등) 핸들러는:

```typescript
async function handleDeliveryDispatched(event) {
  // Layer 1: ProcessedEvent
  const processed = await db.processedEvent.findUnique({ where: { eventId: event.id }});
  if (processed) return;  // 이미 처리됨

  await db.$transaction(async (tx) => {
    // Layer 2: movement UNIQUE
    try {
      await tx.inventoryMovement.create({
        data: {
          // ...
          sourceType: 'DELIVERY',
          sourceId: `dlv:${event.deliveryId}`,
          direction: 'OUT',
          qty: event.qty,
        }
      });
    } catch (e) {
      if (isUniqueViolation(e)) return;  // 멱등: 이미 INSERT 됨
      throw e;
    }
    // 잔고 UPDATE (EI-130)
    await updateBalance(tx, /* ... */);

    // ProcessedEvent 마킹
    await tx.processedEvent.create({ data: { eventId: event.id }});
  });
}
```

### EI-115. 멱등 키 명명 (MUST)

- 짧고 결정적 (외부 ID + 라인 / 시점)
- 같은 외부 트리거가 여러 번 와도 같은 키 생성
- 사용자 입력 (MANUAL) 은 클라이언트 ULID 강제

---

## 3. Direction (EI-120 ~ EI-129)

### EI-120. 방향별 의미 (MUST)

| direction | 잔고 영향 | qty 부호 | 비고 |
|---|---|---|---|
| `IN` | (warehouse, location) 잔고 +qty | 항상 양수 | 매입 입고, 반품 입고 |
| `OUT` | (warehouse, location) 잔고 -qty | 항상 양수 (qty 자체는 양수) | 출고, 폐기 |
| `TRANSFER` | from -qty, to +qty (별도 row 1쌍 또는 단일 row 양쪽 처리) | 양수 | 창고 / 빈 간 이동 |
| `ADJUSTMENT` | 잔고 ±qty (signed_qty 별도) | 양수 + signed_qty | 실사 차이, 손실 |

### EI-121. ADJUSTMENT 의 부호 (MUST)

`qty` 는 항상 양수. ADJUSTMENT 는 추가 컬럼 또는 reason 으로 +/- 표현:

```sql
ALTER TABLE inventory_movements
  ADD COLUMN signed_qty NUMERIC(14, 4);
-- IN/TRANSFER(to)/ADJUSTMENT(+) = +qty
-- OUT/TRANSFER(from)/ADJUSTMENT(-) = -qty
```

balance 갱신 시 signed_qty 사용. 검증:
```
CHECK (
  (direction IN ('IN') AND signed_qty = qty) OR
  (direction IN ('OUT') AND signed_qty = -qty) OR
  (direction = 'ADJUSTMENT' AND ABS(signed_qty) = qty) OR
  (direction = 'TRANSFER')  -- 양쪽 row 쌍, 부호 다름
)
```

### EI-125. TRANSFER 모델링 (MUST)

선택지:
- **옵션 A — 1쌍 movement** (OUT + IN): 같은 source_id 의 짝 row 2개. paired_id 로 연결.
- **옵션 B — 단일 movement (양쪽 정보)**: from_* + to_* 컬럼 함께. 잔고 갱신 시 양쪽.

권장: **옵션 A** — 멱등 / 정합 / 시점별 잔고 추적 모두 명확. paired_id (같은 ULID) 로 짝 식별.

---

## 4. 트랜잭션 / 잔고 갱신 (EI-130 ~ EI-149)

### EI-130. 단일 DB 트랜잭션 (MUST)

movement INSERT + balance UPDATE = 단일 트랜잭션. **Saga 사용 안 함** (단일 모듈 내 정합):

```typescript
await db.$transaction(async (tx) => {
  // 1. balance 행 락 (낙관락 또는 SELECT FOR UPDATE)
  const balance = await tx.$queryRaw`
    SELECT * FROM inventory_balances
    WHERE item_id = ${itemId} AND warehouse_id = ${warehouseId} AND location_id = ${locationId}
    FOR UPDATE
  `;

  // 2. 음수 검증 (EI-140)
  if (direction === 'OUT' || direction === 'TRANSFER_FROM') {
    const available = balance.qty - balance.reserved_qty;
    if (available < requestedQty) throw new InsufficientStockError(/* ... */);
  }

  // 3. movement INSERT
  const mov = await tx.inventoryMovement.create({ data: { ... } });

  // 4. balance UPDATE
  await tx.inventoryBalance.upsert({
    where: { /* unique */ },
    create: { qty: signedQty, /* ... */ },
    update: { qty: { increment: signedQty }, version: { increment: 1 }}
  });

  // 5. 이벤트 발행 (outbox)
  await tx.eventOutbox.create({ data: {
    eventType: 'inventory.movement.recorded',
    payload: { movementId: mov.id, /* ... */ }
  }});
});
```

### EI-135. 동시성 안전 (MUST)

- 행 락: `SELECT ... FOR UPDATE` 또는
- 낙관락: balance 의 `version` 컬럼 + UPDATE WHERE version = ?
- 권장: **낙관락** (락 보유 시간 짧음, 데드락 회피)

낙관락 충돌 시 retry (max 3회, exponential backoff).

### EI-140. 음수 재고 차단 (MUST)

가용 재고 = `qty - reserved_qty - allocated_qty`.

```typescript
function checkAvailability(balance, requested) {
  const available = balance.qty - balance.reservedQty - balance.allocatedQty;
  if (available < requested) {
    throw new InsufficientStockError({
      itemId: balance.itemId,
      requested, available,
      shortfall: requested - available
    });
  }
}
```

게이트 토글: `inventory.negative_stock_block` (기본 ON). OFF 면 경고만.

> ⚠️ OFF 권장하지 않음. 운영상 부득이한 경우 (실시간 동시성 / 회계 마감 등) 만 OFF, 기록 + 알림 강제.

### EI-145. 음수 잔고 사후 검증 (SHOULD)

매일 cron — 모든 (item, warehouse, location) 잔고 검증:
```sql
SELECT * FROM inventory_balances
WHERE qty - reserved_qty - allocated_qty < 0;
```
음수 발견 시 즉시 알림 + 운영자 조사.

---

## 5. 정정 / 취소 (EI-150 ~ EI-169)

### EI-150. UPDATE 금지 / 역 movement (MUST)

이미 INSERT 된 movement 는 UPDATE 금지. 잘못된 movement 정정:

1. 원 movement 의 `status = CANCELLED` 전이 (잔고 영향 X — 단순 표시)
2. **동일한 시점 / 양 / 반대 방향** 의 새 movement INSERT (source_type=`REVERSAL`, source_id=`rev:{original_id}`)
3. 잔고는 새 row 의 signed_qty 로 자동 갱신

```typescript
async function reverseMovement(originalId: string, reason: string) {
  await db.$transaction(async (tx) => {
    const orig = await tx.inventoryMovement.findUnique({ where: { id: originalId }});
    if (!orig) throw new NotFoundError();
    if (orig.status === 'CANCELLED') throw new AlreadyCancelledError();

    // 1. 원 row CANCELLED
    await tx.inventoryMovement.update({
      where: { id: originalId },
      data: { status: 'CANCELLED' }
    });

    // 2. 역 movement INSERT
    const reverseDir = orig.direction === 'IN' ? 'OUT'
                     : orig.direction === 'OUT' ? 'IN'
                     : orig.direction;  // TRANSFER/ADJUSTMENT 별도 처리
    await createMovement(tx, {
      ...orig,
      direction: reverseDir,
      signedQty: -orig.signedQty,
      sourceType: 'REVERSAL',
      sourceId: `rev:${originalId}`,
      reason
    });
  });
}
```

### EI-155. CANCELLED 상태 의미 (MUST)

- ACTIVE: 정상 movement, 잔고 반영됨
- CANCELLED: 사후 무효화 표시. **잔고 영향 자체는 변경 X** (이미 반영). 잔고 정정은 역 movement 만 수행.

CANCELLED 의 본 목적은 **감사 / 추적용 표시**. 운영자가 "이 movement 가 잘못됐다" 라고 마킹하는 것.

### EI-160. 정정 권한 (MUST)

| 작업 | L3 | L4 | Super |
|---|---|---|---|
| 같은 날 movement 정정 | ✅ | ✅ | ✅ |
| 마감일 이전 정정 | ❌ | ✅ | ⚠️ |
| 회계 마감 후 정정 | ❌ | ❌ (감사 트리거) | ✅ |

---

## 6. 마감 (EI-170 ~ EI-179)

### EI-170. 일/월 마감 (MUST)

- 일 마감: 매일 23:59 cron — 그날 잔고 스냅샷 (`inventory_balance_snapshots`)
- 월 마감: 월말 + 5일 grace period — 마감 후 movement INSERT 차단 (운영자 명시 reopen 필요)

### EI-175. 마감 후 INSERT 차단 (MUST)

```typescript
async function checkClosePeriod(occurredAt: Date) {
  const closed = await getClosedPeriod(orgId, occurredAt);
  if (closed) {
    throw new ClosedPeriodError(`${closed.month} 은 마감되었습니다.`);
  }
}
```

---

## 7. 감사 (EI-190 ~ EI-199)

| action | 시점 |
|---|---|
| `inventory.movement.recorded` | INSERT |
| `inventory.movement.cancelled` | status → CANCELLED |
| `inventory.movement.reversed` | REVERSAL row 생성 |
| `inventory.movement.insufficient_stock` | 음수 차단 발생 |
| `inventory.movement.closed_period_block` | 마감 후 시도 |

---

## 8. 참조

- 잔고 갱신: `stock_balance.md` (EI-200~)
- 로트 처리: `lot_tracking.md` (EI-300~)
- 음수 차단 토글: `feature_flags.md` (`inventory.negative_stock_block`)
- 평가 단가: `valuation.md` (EI-600~)
- 스키마: `../schemas/tables/inventory_movements.sql`
