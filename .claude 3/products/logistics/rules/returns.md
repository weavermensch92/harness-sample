# 반품 / 회수 (Returns)

> **ID 범위**: EL-500 ~ EL-599
> **주제**: 반품 / 회수 / RMA 처리, 역배송, inventory 환원
> **상위**: `INDEX.md`
> **게이트 토글**: `logistics.return_handling` (기본 ON)

---

## TL;DR

- **반품 = direction='RETURN' delivery 새 row** — 원 delivery 와 `parent_delivery_id` 로 link.
- **lifecycle**: REQUESTED → APPROVED → PICKED_UP → RECEIVED → INSPECTED → COMPLETED / REJECTED.
- **반품 사유 분류** (KR 전자상거래법) — 단순변심 / 상품하자 / 오배송 / 시스템오류. 사유별 비용 부담자 분기.
- **inventory 환원**: RECEIVED 시점에 IN movement 생성. lot_id 보존 (원 출고 lot 와 동일).
- **검수 (Inspection)** — RECEIVED → INSPECTED 단계에서 품질 / 수량 검증. PASS / PARTIAL / FAIL.
- **냉장 / 냉동 / 식품 / 의약품** — 반품 자체 거부 가능 (위생 / 안전).
- **환불 트리거** — RECEIVED 시점 또는 INSPECTED PASS 시점에 외부 환불 시스템 이벤트 발행.

핵심 ID: EL-510 (모델) / EL-520 (lifecycle) / EL-530 (사유 / 비용) / EL-540 (inventory 환원) / EL-550 (검수)

---

## 1. 모델 (EL-500 ~ EL-519)

### EL-510. return_request 모델 (MUST)

```sql
CREATE TABLE logistics_return_requests (
  id                    UUID PRIMARY KEY,
  organization_id       UUID NOT NULL,
  original_delivery_id  UUID NOT NULL,
  return_delivery_id    UUID,                       -- RETURN direction delivery (수거 발생 시)

  request_source        VARCHAR(20) NOT NULL,       -- CUSTOMER / SYSTEM / OPERATOR
  reason                VARCHAR(30) NOT NULL,       -- CUSTOMER_REGRET / DEFECT / WRONG_ITEM / DAMAGED_TRANSIT / SYSTEM_ERROR
  reason_detail         TEXT,

  status                VARCHAR(20) NOT NULL DEFAULT 'REQUESTED',
  -- REQUESTED / APPROVED / REJECTED / PICKED_UP / RECEIVED / INSPECTED / COMPLETED / CANCELLED

  -- 비용 부담자
  cost_bearer           VARCHAR(20),                -- BUYER / SELLER / CARRIER

  -- 검수 결과
  inspection_result     VARCHAR(20),                -- PASS / PARTIAL / FAIL
  inspection_notes      TEXT,
  inspected_by          UUID,
  inspected_at          TIMESTAMPTZ,

  -- 환불
  refund_status         VARCHAR(20),                -- PENDING / ISSUED / DECLINED
  refund_amount         NUMERIC(14, 0),

  requested_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_at           TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,

  UNIQUE (organization_id, original_delivery_id),   -- 1 원 배송 = 1 반품 (Phase 0 단순화)
  CONSTRAINT fk_return_original FOREIGN KEY (original_delivery_id) REFERENCES logistics_deliveries(id) ON DELETE RESTRICT,
  CONSTRAINT fk_return_delivery FOREIGN KEY (return_delivery_id)   REFERENCES logistics_deliveries(id) ON DELETE RESTRICT
);
```

> Phase 1+: 부분 반품 / 다수 시도는 별도 모델링 필요.

### EL-512. return_lines (MUST)

```sql
CREATE TABLE logistics_return_lines (
  id              UUID PRIMARY KEY,
  return_request_id UUID NOT NULL,
  delivery_line_id UUID NOT NULL,                   -- 원 배송 라인
  qty             NUMERIC(14, 4) NOT NULL,          -- 반품 수량 (원 qty 이하)
  inspection_status VARCHAR(20),                    -- PASS / DAMAGED / WRONG / MISSING
  notes           TEXT,
  UNIQUE (return_request_id, delivery_line_id)
);
```

---

## 2. Lifecycle (EL-520 ~ EL-529)

### EL-520. 상태 머신 (MUST)

```
REQUESTED  →  APPROVED  →  PICKED_UP  →  RECEIVED  →  INSPECTED  →  COMPLETED
     ↓             ↓                                       ↓
  REJECTED      CANCELLED                              REJECTED (검수 실패)
```

| 상태 | 의미 | 다음 |
|---|---|---|
| `REQUESTED` | 고객 / 시스템 요청 | APPROVED, REJECTED |
| `APPROVED` | 운영자 승인 + 수거 일정 | PICKED_UP, CANCELLED |
| `REJECTED` | 거부 (반품 불가) | (종결) |
| `PICKED_UP` | 수거 완료 (운송 중) | RECEIVED |
| `RECEIVED` | 창고 도착 | INSPECTED |
| `INSPECTED` | 검수 완료 | COMPLETED, REJECTED |
| `COMPLETED` | 환불 완료 / 모든 처리 종결 | (종결) |

### EL-525. RETURN delivery 생성 시점 (MUST)

`APPROVED` 단계 — 새 logistics_deliveries row INSERT (direction='RETURN'):
- recipient_* = 원 발송 창고 (역방향)
- 원 delivery 의 lines 와 동일 (qty 는 반품 qty)
- parent_delivery_id = original_delivery_id

```typescript
const returnDelivery = await tx.delivery.create({
  data: {
    direction: 'RETURN',
    organizationId: original.organizationId,
    recipientName: original.warehouseAddress,  // 회사 창고
    parentDeliveryId: original.id,
    // ...
  }
});
await tx.returnRequest.update({
  where: { id: returnRequestId },
  data: { status: 'APPROVED', returnDeliveryId: returnDelivery.id, approvedAt: new Date() }
});
```

---

## 3. 사유 / 비용 부담 (EL-530 ~ EL-549) — KR 전자상거래법

### EL-530. 사유 분류 (MUST)

전자상거래법 §17 (청약철회) + §18 (효과):

| 사유 코드 | 의미 | 비용 부담자 (KR 기본) |
|---|---|---|
| `CUSTOMER_REGRET` | 단순변심 | 고객 (BUYER) |
| `DEFECT` | 상품 하자 | 판매자 (SELLER) |
| `WRONG_ITEM` | 오배송 | 판매자 (SELLER) |
| `DAMAGED_TRANSIT` | 운송 중 파손 | carrier 또는 SELLER (carrier 보험) |
| `SYSTEM_ERROR` | 시스템 오류 | SELLER |

`cost_bearer` 컬럼에 자동 / 운영자 결정.

### EL-535. 청약철회 기간 (MUST, KR)

전자상거래법 §17 ① — **상품 수령 후 7일 이내** (단순변심 한정).

조건:
- DELIVERED 후 7일 이내 → 단순변심 가능
- 7일 초과 → 단순변심 거부 가능 (DEFECT / 오배송 등은 별도 적용)

```typescript
function canRequestReturnByRegret(originalDelivery, requestedAt) {
  if (!originalDelivery.completedAt) return false;
  const days = differenceInDays(requestedAt, originalDelivery.completedAt);
  return days <= 7;
}
```

### EL-540. 청약철회 제한 (MUST, KR)

전자상거래법 §17 ② — 다음은 단순변심 거부 가능:
- 사용 / 일부 소비된 상품
- 시간 경과로 가치가 현저히 떨어진 상품 (식품 / 농수산물)
- 복제 가능 디지털 콘텐츠 (개봉 후)
- 주문 제작 (커스텀)
- 의약품 (약사법 별도)

### EL-545. cost_bearer 정책 자동화 (MUST)

```typescript
function determineCostBearer(reason, carrier) {
  switch (reason) {
    case 'CUSTOMER_REGRET':  return 'BUYER';
    case 'DEFECT':           return 'SELLER';
    case 'WRONG_ITEM':       return 'SELLER';
    case 'DAMAGED_TRANSIT':  return carrier === 'self' ? 'SELLER' : 'CARRIER';
    case 'SYSTEM_ERROR':     return 'SELLER';
    default:                 return 'SELLER';   // 분쟁 시 기본은 판매자
  }
}
```

운영자가 자동값 override 가능 (audit).

---

## 4. inventory 환원 (EL-550 ~ EL-559)

### EL-550. RECEIVED 시점 IN movement (MUST)

```typescript
async function handleReturnReceived(returnRequestId) {
  await db.$transaction(async (tx) => {
    const r = await tx.returnRequest.findUnique({
      where: { id: returnRequestId },
      include: { lines: { include: { deliveryLine: true }}}
    });

    for (const line of r.lines) {
      // inventory IN movement (v0.2: movement_source.RETURN 정합)
      await createInventoryMovement(tx, {
        direction: 'IN',
        itemId: line.deliveryLine.itemId,
        warehouseId: r.targetWarehouseId,    // RETURN 창고 (보통 RETURN type)
        lotId: line.deliveryLine.lotId,      // 원 lot 보존
        qty: line.qty,
        sourceType: 'RETURN',                // v0.2 마이그레이션 001 후 사용 가능
        sourceId: `rtn:${r.id}:${line.id}`   // inventory stock_movement EI-110 정합 prefix
      });
    }
    await tx.returnRequest.update({
      where: { id: returnRequestId },
      data: { status: 'RECEIVED' }
    });
  });
}
```

> ✅ v0.2 마이그레이션 001 적용 후 `movement_source.RETURN` 활성. 별도 처리 불필요.

### EL-555. RETURN 창고 (SHOULD)

검수 전까지는 `warehouse_type = RETURN` 또는 `QUARANTINE` 창고에 보관:
- 일반 창고와 분리 → 재판매 / 폐기 결정 전
- 검수 PASS → 일반 창고로 TRANSFER
- 검수 FAIL → 폐기 (DISPOSAL movement)

---

## 5. 검수 (Inspection) (EL-560 ~ EL-569)

### EL-560. 검수 절차 (MUST)

```typescript
async function inspectReturn(returnRequestId, lines, inspector) {
  await db.$transaction(async (tx) => {
    let allPass = true;
    let anyPass = false;
    for (const l of lines) {
      await tx.returnLine.update({
        where: { id: l.id },
        data: { inspectionStatus: l.inspectionStatus, notes: l.notes }
      });
      if (l.inspectionStatus !== 'PASS') allPass = false;
      else anyPass = true;
    }
    const result = allPass ? 'PASS' : (anyPass ? 'PARTIAL' : 'FAIL');
    await tx.returnRequest.update({
      where: { id: returnRequestId },
      data: { status: 'INSPECTED', inspectionResult: result, inspectedBy: inspector.id, inspectedAt: new Date() }
    });
  });
}
```

### EL-565. 검수 결과별 처리 (MUST)

| 결과 | 처리 |
|---|---|
| PASS | 환불 진행 + inventory 일반 창고로 TRANSFER (재판매 가능) |
| PARTIAL | 부분 환불 + 일부만 일반 창고 / 일부 폐기 |
| FAIL | 환불 거부 또는 부분 환불 (cost_bearer 정책) + 폐기 movement |

### EL-568. 식품 / 의약품 거부 (MUST, KR)

위생 / 안전 사유로 일부 카테고리는 검수 자체 불가능:
- 개봉된 식품 — 위생 위험, 폐기 (재판매 X)
- 개봉된 의약품 — 약사법, 폐기
- 냉장 / 냉동 (콜드체인 끊김) — 폐기

이런 경우 검수 단계에서 자동 FAIL + 폐기 처리.

---

## 6. 환불 트리거 (EL-570 ~ EL-579)

### EL-570. 시점 (MUST)

- INSPECTED PASS / PARTIAL → 즉시 환불 이벤트 발행
- INSPECTED FAIL → 환불 X (cost_bearer 가 SELLER 면 일부 환불, 운영자 결정)

```typescript
await tx.eventOutbox.create({
  data: {
    eventType: 'REFUND_REQUESTED',
    payload: {
      orderId: r.original.orderId,
      amount: r.refundAmount,
      reason: r.reason,
      returnRequestId: r.id
    }
  }
});
```

### EL-575. 환불 금액 산정 (MUST, KR)

전자상거래법 §18:
- 단순변심: 상품 가격 환불 + **편도 배송비 고객 부담**
- DEFECT / 오배송 / 시스템오류: 상품 가격 + **왕복 배송비 판매자 부담**

```typescript
function calcRefundAmount(returnRequest) {
  const base = returnRequest.lines.reduce((s, l) => s + l.qty * l.deliveryLine.unitPrice, 0);
  const shipping = returnRequest.original.shippingCost;
  switch (returnRequest.costBearer) {
    case 'BUYER':   return base - shipping;        // 고객 부담 = 배송비 차감
    case 'SELLER':  return base + shipping;        // 판매자 부담 = 왕복 배송비 추가
    case 'CARRIER': return base + shipping;        // carrier 가 SELLER 측에 후 청구
  }
}
```

---

## 7. 권한 / 감사 (EL-580 ~ EL-599)

### EL-580. 권한

| 작업 | L1 (고객) | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 반품 요청 | ✅ (본인) | — | ✅ | ✅ | ✅ |
| 반품 승인 / 거부 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 검수 결과 입력 | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 환불 승인 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| cost_bearer 변경 | ❌ | ❌ | ⚠️ | ✅ | ⚠️ |
| 청약철회 기간 외 단순변심 승인 | ❌ | ❌ | ❌ | ✅ (audit) | ✅ |

### EL-590. 감사

| action | 시점 |
|---|---|
| `logistics.return.requested` | 요청 |
| `logistics.return.approved` | 승인 + RETURN delivery 생성 |
| `logistics.return.rejected` | 거부 |
| `logistics.return.received` | 창고 입고 (inventory IN) |
| `logistics.return.inspected` | 검수 완료 |
| `logistics.return.refunded` | 환불 발행 |
| `logistics.return.regret_period_overridden` | 7일 초과 단순변심 승인 (예외) |

---

## 8. 참조

- 게이트: `feature_flags.md` (`logistics.return_handling`)
- delivery 모델: `delivery.md` § EL-010
- inventory 환원 (RETURN movement): `../../inventory/rules/stock_movement.md` (EI-100)
- 전자상거래법 §17, §18 — 청약철회 / 효과
- 스키마: `../schemas/tables/logistics_return_requests.sql`
