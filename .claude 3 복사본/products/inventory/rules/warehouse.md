# 창고 / 위치 (Warehouse / Location)

> **ID 범위**: EI-400 ~ EI-499
> **주제**: 물리 / 논리 위치 계층, 빈 단위 관리
> **상위**: `INDEX.md`
> **게이트 토글**: `inventory.multi_warehouse` (다중 창고), `inventory.location_bin` (빈 단위)

---

## TL;DR

- **계층**: organization → facility → warehouse → location (zone / aisle / bin). 4단계.
- **warehouse** = 물리 / 논리 창고. 단일 사업장 가능 (multi_warehouse OFF 시 1개).
- **location** = 창고 내부 위치 (구역 / 통로 / 빈). bin 단위 토글 (`inventory.location_bin`) OFF 시 NULL 허용.
- **상태**: ACTIVE / INACTIVE / FROZEN (잔고 있어도 신규 입출고 차단).
- **위치 트리** — parent_id self-FK. 깊이 4단계 권장.
- **이동 (TRANSFER)** — 같은 warehouse 내 location 간 또는 warehouse 간. 양쪽 movement 한 쌍.

핵심 ID: EI-410 (warehouse) / EI-420 (location 트리) / EI-430 (상태 / FROZEN) / EI-440 (이동)

---

## 1. warehouse 모델 (EI-400 ~ EI-419)

### EI-410. 핵심 필드 (MUST)

```sql
CREATE TABLE inventory_warehouses (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  facility_id     UUID,                           -- NULL = 사업장 무관 / 본사 창고
  code            VARCHAR(20) NOT NULL,           -- 'WH-MAIN', 'WH-COLD-A'
  name            VARCHAR(200) NOT NULL,
  warehouse_type  VARCHAR(20) NOT NULL,           -- MAIN / COLD / DISTRIBUTION / RETURN / QUARANTINE
  address         TEXT,
  status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  -- ACTIVE / INACTIVE / FROZEN
  meta            JSONB,                          -- 온도조건, 보안등급 등
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, code)
);
```

### EI-411. warehouse_type 카탈로그

| 타입 | 의미 | 특이사항 |
|---|---|---|
| `MAIN` | 일반 창고 | 기본 |
| `COLD` | 냉장 / 냉동 | 온도 메타 필수, 식품 / 의약품 |
| `DISTRIBUTION` | 물류 거점 | 단기 보관 |
| `RETURN` | 반품 / 검수 | 별도 잔고, 통상 QUARANTINED lot |
| `QUARANTINE` | 검역 | 입고 검수 전 |

### EI-415. 다중 창고 토글 (MUST)

`inventory.multi_warehouse = OFF` 인 조직:
- warehouse 는 자동으로 1개 (default warehouse) 만 운영
- 신규 warehouse INSERT 거부
- movement / balance 의 warehouse_id 는 default 강제

→ 단순 환경 (단일 매장 / 단일 창고) 에서 UI / 운영 단순화.

---

## 2. location 트리 (EI-420 ~ EI-439)

### EI-420. 모델 (MUST)

```sql
CREATE TABLE inventory_locations (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  parent_id       UUID,                           -- self-FK, NULL = 최상위
  code            VARCHAR(50) NOT NULL,           -- 'A-01-03' 등
  name            VARCHAR(200),
  location_type   VARCHAR(20) NOT NULL,           -- ZONE / AISLE / RACK / BIN
  depth           SMALLINT NOT NULL,              -- 1=ZONE / 2=AISLE / 3=RACK / 4=BIN
  status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  capacity        NUMERIC(14, 4),                 -- 옵션 — 최대 수용량
  meta            JSONB,
  UNIQUE (warehouse_id, code)
);
```

### EI-425. 깊이 제약 (MUST)

```sql
CHECK (depth >= 1 AND depth <= 4)
CHECK (
  (parent_id IS NULL AND depth = 1) OR
  (parent_id IS NOT NULL AND depth >= 2)
)
```

### EI-428. 빈 단위 토글 (MUST)

`inventory.location_bin = OFF` 인 조직:
- location 자체를 사용하지 않음. balance / movement 의 location_id NULL.
- 또는 단일 default location (창고 = location) 강제.

→ 소규모 창고 (단일 빈 / 자유배치) 에서 운영 단순화.

---

## 3. 상태 / FROZEN (EI-430 ~ EI-439)

### EI-430. 상태 의미 (MUST)

| 상태 | 신규 입고 | 신규 출고 | 잔고 조회 | 비고 |
|---|---|---|---|---|
| `ACTIVE` | ✅ | ✅ | ✅ | 정상 |
| `INACTIVE` | ❌ | ❌ | ✅ | 사용 중지 (잔고 0 권장) |
| `FROZEN` | ❌ | ❌ | ✅ | 일시 잠금 (실사 / 감사 / 분쟁) |

### EI-435. FROZEN 유스케이스

- 재고 실사 진행 중 (`cycle_count.md` EI-510)
- 분쟁 / 회계 감사
- 시스템 마이그레이션

FROZEN 해제 권한: L4. audit 필수.

---

## 4. 이동 (Transfer) (EI-440 ~ EI-449)

### EI-440. warehouse 간 이동 (MUST)

`stock_movement.md` EI-125 의 옵션 A 적용 — OUT + IN 짝 movement.

```typescript
async function transferBetweenWarehouses(item, fromWh, toWh, qty) {
  await db.$transaction(async (tx) => {
    const transferId = ulid();
    // 1. OUT (from)
    await createMovement(tx, {
      direction: 'OUT', warehouseId: fromWh, qty,
      sourceType: 'TRANSFER_INTERNAL', sourceId: `tr:${transferId}:from`,
      pairedId: transferId
    });
    // 2. IN (to)
    await createMovement(tx, {
      direction: 'IN', warehouseId: toWh, qty,
      sourceType: 'TRANSFER_INTERNAL', sourceId: `tr:${transferId}:to`,
      pairedId: transferId
    });
  });
}
```

### EI-445. in-transit 잔고 (옵션, Phase 1+)

긴 거리 이동의 경우 "in-transit" 가상 location 운영:
- OUT (from) → in-transit (가상)
- in-transit → IN (to) [수령 확인 시점]

기본은 단순화 (OUT + IN 동시).

---

## 5. 권한 / 감사 (EI-480 ~ EI-499)

### EI-480. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| warehouse / location 조회 | ✅ | ✅ | ✅ | ✅ |
| location 신규 등록 | ❌ | ✅ | ✅ | ⚠️ |
| warehouse 신규 등록 | ❌ | ❌ | ✅ | ⚠️ |
| FROZEN ↔ ACTIVE | ❌ | ❌ | ✅ | ⚠️ |
| TRANSFER 실행 | ❌ | ✅ | ✅ | ⚠️ |

### EI-490. 감사

| action | 시점 |
|---|---|
| `inventory.warehouse.created` | 신규 창고 |
| `inventory.location.created` | 신규 위치 |
| `inventory.warehouse.frozen` | FROZEN 전이 |
| `inventory.transfer.executed` | TRANSFER 실행 |

---

## 6. 참조

- 게이트: `feature_flags.md` (`inventory.multi_warehouse`, `inventory.location_bin`)
- 이동 모델: `stock_movement.md` (EI-125)
- 잔고 키: `stock_balance.md` (EI-200)
- 스키마: `../schemas/tables/inventory_warehouses.sql`, `inventory_locations.sql`
