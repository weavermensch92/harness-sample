# 재고 평가 (Valuation)

> **ID 범위**: EI-600 ~ EI-699
> **주제**: 재고 원가 산정 (FIFO / 이동평균), 평가손익, 회계 통합
> **상위**: `INDEX.md`
> **게이트 토글**: `inventory.valuation_fifo` 또는 `inventory.valuation_moving_avg` (둘 중 택 1)

---

## TL;DR

- **방법 2종**: FIFO (선입선출) / Moving Average (이동평균). 조직 단위 정책.
- **K-IFRS / K-GAAP** — 한국 회계 기준은 FIFO / 가중평균 / 표준원가 허용. LIFO 금지.
- **단가 = unit_cost** (원/base_uom). IN movement 시 결정. OUT 은 평가 방법에 따라 산정.
- **방법 변경은 회계 결산 시점만** — 사업연도 중간 변경 금지 (회계 일관성).
- **평가손실 인식** — 시가 < 장부 단가 시 평가감 (저가법, K-IFRS §2.9).
- **평가 시점**: 매월 마감 / 분기말 / 연말. movement 별 자동 + 수기 평가 보고서.

핵심 ID: EI-610 (FIFO) / EI-620 (이동평균) / EI-630 (방법 변경) / EI-640 (저가법)

---

## 1. 핵심 모델 (EI-600 ~ EI-609)

### EI-600. 평가 단가 보관 (MUST)

`inventory_movements` 의 `unit_cost` / `total_cost`:
- IN movement: unit_cost 기록 (구매 단가 + 부대비용)
- OUT movement: 평가 방법에 따라 산정 (FIFO / Avg)
- ADJUSTMENT: 옵션 (조직 정책)

### EI-605. OUT 단가 = 출고 시점 결정 (MUST)

OUT movement INSERT 시 unit_cost 즉시 확정 — 사후 변경 X.

```typescript
async function determineOutboundUnitCost(itemId, warehouseId, qty, method) {
  switch (method) {
    case 'FIFO':       return await pickFifoLayers(itemId, warehouseId, qty);
    case 'MOVING_AVG': return await getCurrentAvgCost(itemId, warehouseId);
  }
}
```

---

## 2. FIFO (EI-610 ~ EI-619)

### EI-610. FIFO 레이어 (MUST)

각 IN movement = "레이어" 1개 — `inventory_cost_layers`:

```sql
CREATE TABLE inventory_cost_layers (
  id              UUID PRIMARY KEY,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  in_movement_id  UUID NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL,
  initial_qty     NUMERIC(14, 4) NOT NULL,
  remaining_qty   NUMERIC(14, 4) NOT NULL,
  unit_cost       NUMERIC(14, 0) NOT NULL,
  status          VARCHAR(20) NOT NULL,           -- ACTIVE / DEPLETED
  UNIQUE (in_movement_id)
);
```

### EI-615. FIFO 출고 (MUST)

received_at 빠른 레이어부터 차감:

```typescript
async function pickFifoLayers(itemId, warehouseId, qty) {
  const layers = await tx.inventoryCostLayer.findMany({
    where: { itemId, warehouseId, status: 'ACTIVE' },
    orderBy: { receivedAt: 'asc' }
  });
  let remaining = qty;
  let totalCost = 0n;
  for (const layer of layers) {
    if (remaining <= 0) break;
    const take = Math.min(layer.remainingQty, remaining);
    totalCost += BigInt(Math.round(take * Number(layer.unitCost)));
    await tx.inventoryCostLayer.update({
      where: { id: layer.id },
      data: { remainingQty: { decrement: take },
              status: layer.remainingQty - take === 0 ? 'DEPLETED' : 'ACTIVE' }
    });
    remaining -= take;
  }
  if (remaining > 0) throw new InsufficientFifoLayersError();
  return Number(totalCost) / qty;  // 평균 출고 단가
}
```

### EI-618. lot 추적과 정합 (MUST)

LOT 추적 품목은 layer = lot 1:1 권장. FIFO + FEFO 결합:
- 기본: FIFO (입고 순)
- `inventory.fefo_dispatch = ON` 시: FEFO 우선 (만료 임박)

---

## 3. 이동평균 (EI-620 ~ EI-629)

### EI-620. 평균 단가 갱신 (MUST)

매 IN movement 시:
```
new_avg = (old_avg × old_qty + new_unit_cost × new_qty) / (old_qty + new_qty)
```

```sql
CREATE TABLE inventory_avg_costs (
  id              UUID PRIMARY KEY,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  current_qty     NUMERIC(14, 4) NOT NULL,
  current_avg_cost NUMERIC(14, 4) NOT NULL,
  last_updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE (item_id, warehouse_id)
);
```

### EI-625. 출고 시 적용 (MUST)

OUT 시 평균 단가 그대로 사용:
- unit_cost = current_avg_cost
- current_qty -= qty (current_avg_cost 변경 X — 출고는 평균에 영향 없음)

### EI-628. 음수 잔고 + 평균 단가 (MUST)

음수 잔고에서 입고가 들어오면 평균 단가 왜곡. `inventory.negative_stock_block = OFF` 인 조직은 이동평균 X (FIFO 만 허용).

---

## 4. 방법 변경 (EI-630 ~ EI-639)

### EI-630. 변경 시점 (MUST, K-IFRS)

회계 일관성 원칙 — 사업연도 중간 변경 금지.

가능 시점:
- 새 사업연도 첫째 날
- 신규 사업장 / 신규 품목군 도입 시

### EI-635. 변경 절차 (MUST)

1. 회계 마감 (전 사업연도 결산)
2. 변경 결의 (이사회 / 회계법인)
3. 평가 단가 재계산 (스냅샷)
4. 토글 변경
5. 비교 보고서 (기존 vs 신 방법 평가액 차이)

### EI-639. K-IFRS 공시

방법 변경 시 재무제표 주석 공시 의무 — 변경 사유 / 영향액. ERP 자체는 이력 보존 + 보고서.

---

## 5. 저가법 / 평가감 (EI-640 ~ EI-649) — K-IFRS §2.9

### EI-640. 시가 비교 (MUST)

월말 / 분기말 — 장부단가 vs NRV (순실현가능가치):
```
NRV = 예상 판매가 - 예상 처리비용
장부단가 > NRV → 평가손실 인식
```

### EI-645. 평가손실 movement (옵션)

별도 ADJUSTMENT (signed_qty=0 + total_cost 차이) 또는 별도 `inventory_valuation_adjustments` 테이블 (Phase 1+).

### EI-648. 회수 (MUST, K-IFRS)

평가감 후 NRV 회복 시 — 한도 내 회수 (전기 평가감만큼). 평가감보다 더 많이 회복 X.

---

## 6. 보고서 (EI-650 ~ EI-669)

### EI-650. 월별 평가 보고서 (MUST)

월말 자동 생성:
- 품목별 / 창고별 잔고 × 평가단가 = 평가액
- 전월 대비 증감 (입고 / 출고 / 평가감)
- Reports 모듈 연동

### EI-655. 표시 단위

- 평가액 = NUMERIC(14, 0) KRW 정수
- 단가 = NUMERIC(14, 4) (정밀도 보존)
- 보고서 표시 단가 0~2자리 (조직 정책)

---

## 7. 권한 / 감사 (EI-680 ~ EI-699)

### EI-680. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| 평가 단가 조회 | ❌ | ✅ | ✅ | ✅ |
| 평가 보고서 조회 | ❌ | ✅ | ✅ | ✅ |
| 저가법 평가감 승인 | ❌ | ❌ | ✅ | ⚠️ |
| 평가 방법 변경 | ❌ | ❌ | ❌ | ✅ (회계 결산 시점만) |
| FIFO 레이어 직접 수정 | **금지** | | | ⚠️ Super 비상시 |

### EI-690. 감사

| action | 시점 |
|---|---|
| `inventory.fifo_layer.created` | IN 시 레이어 생성 |
| `inventory.fifo_layer.depleted` | 레이어 소진 |
| `inventory.avg_cost.updated` | 평균 단가 갱신 |
| `inventory.valuation.method_changed` | 방법 변경 |
| `inventory.valuation.write_down` | 평가감 인식 |
| `inventory.valuation.recovery` | 평가감 회복 |

---

## 8. 참조

- 게이트: `feature_flags.md` (`inventory.valuation_fifo` / `inventory.valuation_moving_avg`)
- movement unit_cost: `stock_movement.md` (EI-100)
- 잔고: `stock_balance.md`
- FEFO 정합: `lot_tracking.md` (EI-330)
- 스키마: `../schemas/tables/inventory_cost_layers.sql`, `inventory_avg_costs.sql`
