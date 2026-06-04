# 로트 / 시리얼 / 유통기한 (Lot Tracking)

> **ID 범위**: EI-300 ~ EI-399
> **주제**: 로트 (Batch) / 시리얼 / 유통기한 추적, FEFO 출고
> **상위**: `INDEX.md`
> **게이트 토글**: `inventory.lot_tracking` 또는 `inventory.serial_tracking`
> **기준법 (KR)**: 식품위생법 §10, 약사법 §47, 화장품법 §10 (제조번호 / 사용기한 표시 의무)

---

## TL;DR

- **lot_id** = 같은 시점 / 같은 조건에서 입고된 단위. 식품·의약품·화장품에서 KR 법적 추적 의무.
- **시리얼 (serial_no)** = 개별 단위 식별 (가전·의료기기·고가 자산). lot 내 unique.
- **expires_at** = lot 단위 보관. 만료 시 출고 차단 (`inventory.expiry_block_ship`).
- **FEFO** — 만료 임박 lot 우선 출고. 토글 `inventory.fefo_dispatch`.
- **LOT/SERIAL 모드 시 movement / balance 의 lot_id NOT NULL** — item_master 의 tracking_mode 와 정합.
- **만료 알림**: 30일 전 / 7일 전 / 1일 전 / 만료일.

핵심 ID: EI-310 (lot 모델) / EI-330 (FEFO) / EI-340 (만료 처리) / EI-350 (KR 의무)

---

## 1. lot 모델 (EI-300 ~ EI-319)

### EI-300. 핵심 필드 (MUST)

```sql
CREATE TABLE inventory_lots (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  item_id         UUID NOT NULL,
  lot_no          VARCHAR(50) NOT NULL,            -- 제조번호 / 배치번호
  manufactured_at DATE,
  expires_at      DATE,                            -- 사용기한 / 유통기한
  supplier_lot    VARCHAR(50),                     -- 공급사 lot
  meta            JSONB,
  status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  -- ACTIVE / QUARANTINED / EXPIRED / DISPOSED
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, item_id, lot_no)
);
```

### EI-310. lot_no 명명 (SHOULD)

- 사업장 + 품목 단위 unique
- 제조사 / 공급사 lot 그대로 권장
- 영문대문자 / 숫자 / 하이픈 / 언더스코어

### EI-315. lot 라이프사이클 (MUST)

```
ACTIVE  ←→  QUARANTINED  →  DISPOSED  (검역 실패)
   ↓
EXPIRED  →  DISPOSED  (만료 후 폐기)
```

| 상태 | 출고 가능 | 비고 |
|---|---|---|
| `ACTIVE` | ✅ | 정상 |
| `QUARANTINED` | ❌ | 검역 / 품질 검사 중 |
| `EXPIRED` | ❌ (토글 OFF 면 경고) | 유통기한 도래 |
| `DISPOSED` | ❌ | 폐기 완료 |

---

## 2. 시리얼 추적 (EI-320 ~ EI-329)

### EI-320. serial 모델 (MUST)

```sql
CREATE TABLE inventory_serials (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  item_id         UUID NOT NULL,
  lot_id          UUID,                            -- lot 안에 시리얼이면 NOT NULL
  serial_no       VARCHAR(100) NOT NULL,
  current_location_id UUID,
  status          VARCHAR(20) NOT NULL,            -- IN_STOCK / SHIPPED / RETURNED / SCRAPPED
  meta            JSONB,
  UNIQUE (organization_id, item_id, serial_no)
);
```

### EI-325. movement 와 시리얼 (MUST)

`tracking_mode = SERIAL` 인 품목의 movement 1 row = 1 serial. qty 항상 1. 대량은 batch 처리하되 DB 행은 분리.

```sql
ALTER TABLE inventory_movements
  ADD COLUMN serial_id UUID;
```

---

## 3. FEFO 출고 (EI-330 ~ EI-339)

### EI-330. FEFO 정책 (MUST, 토글 ON 시)

토글 `inventory.fefo_dispatch = ON` 인 경우 LOT 추적 품목 출고 / 할당 시:
- expires_at 빠른 lot 우선
- 같은 expires_at 이면 received_at 빠른 lot (보조 FIFO)

```typescript
async function pickLotsForDispatch(itemId, warehouseId, qty) {
  const fefo = await isFeatureEnabled(orgId, 'inventory.fefo_dispatch');
  const orderBy = fefo
    ? `lots.expires_at ASC NULLS LAST, balances.received_at ASC`
    : `balances.received_at ASC`;
  // ... ORDER BY orderBy
}
```

### EI-335. 부분 픽 (MUST)

가용량이 다 차면 다음 lot 으로 누적 — 1 출고가 여러 lot 에서 분할 픽업 가능. 각 lot 마다 별도 movement row.

---

## 4. 만료 처리 (EI-340 ~ EI-349)

### EI-340. 만료 차단 (MUST, 토글 ON)

`inventory.expiry_block_ship = ON` 시:
- expires_at < 오늘 → OUT movement INSERT 거부
- expires_at = 오늘 → 경고 + 운영자 승인
- expires_at > 오늘 → 정상

### EI-345. 만료 일배치 (MUST)

매일 cron (00:30 KST):
1. 오늘 만료된 lot status → EXPIRED
2. 30/7/1일 전 알림
3. `inventory.lot.expired` 이벤트 발행

### EI-348. 만료 폐기 (MUST)

EXPIRED → DISPOSED:
- `EXPIRY_DISPOSAL` source_type 으로 OUT movement (잔고 차감)
- 폐기 사유 / 폐기자 audit
- KR 의약품 등은 폐기 신고 의무 (Phase 2+ 보고서)

---

## 5. KR 도메인 의무 (EI-350 ~ EI-369)

### EI-350. 추적 의무 품목 (KR)

| 산업 | 근거 | tracking_mode |
|---|---|---|
| 식품 (가공/신선) | 식품위생법 §10 | LOT 의무 |
| 의약품 | 약사법 §47 | LOT + SERIAL (일부) |
| 화장품 | 화장품법 §10 | LOT 의무 |
| 의료기기 | 의료기기법 §13 | SERIAL (등급별) |
| 위험물 | 위험물안전관리법 | LOT + 별도 관리 |

### EI-352. 제조번호 / 사용기한 의무 (MUST)

조직 산업 분류 기반 강제:
```typescript
if (org.regulatoryIndustry === 'PHARMA' && trackingMode === 'NONE') {
  throw new RegulatoryViolationError('의약품은 LOT/SERIAL 추적 필수.');
}
```

해당 품목 lot 등록 시 `lot_no` + `expires_at` NOT NULL 강제.

### EI-355. 회수 (Recall) 추적 (MUST)

특정 lot 회수 시 입고 / 출고 / 배송 수령자까지 추적:
```sql
SELECT * FROM inventory_movements WHERE lot_id = $1 ORDER BY occurred_at;
-- + Logistics deliveries JOIN (수령자 정보)
```

---

## 6. 권한 / 감사 (EI-380 ~ EI-399)

### EI-380. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| lot 조회 | ✅ | ✅ | ✅ | ✅ |
| QUARANTINED ↔ ACTIVE | ❌ | ✅ | ✅ | ⚠️ |
| 만료 폐기 | ❌ | ✅ | ✅ | ⚠️ |
| 회수 명령 | ❌ | ❌ | ✅ | ⚠️ |

### EI-390. 감사

| action | 시점 |
|---|---|
| `inventory.lot.created` | 신규 lot |
| `inventory.lot.expired` | 만료 자동 |
| `inventory.lot.disposed` | 폐기 |
| `inventory.lot.recalled` | 회수 명령 |
| `inventory.lot.expiry_block_ship` | 만료 출고 차단 |

---

## 7. 참조

- 게이트: `feature_flags.md` (`inventory.lot_tracking` / `serial_tracking` / `fefo_dispatch` / `expiry_block_ship`)
- 출고 로직: `stock_movement.md` (EI-100~)
- 가용 / 할당: `stock_balance.md` (EI-240~)
- 품목 마스터: `item_master.md` (EI-050~)
- 스키마: `../schemas/tables/inventory_lots.sql`, `inventory_serials.sql`
