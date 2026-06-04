-- ════════════════════════════════════════════════════════════════════════
-- inventory_balances + inventory_reservations
-- 룰 EI-200 ~ EI-299 / 상세: rules/stock_balance.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE inventory_balances (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID            NOT NULL,
  item_id         UUID            NOT NULL,
  warehouse_id    UUID            NOT NULL,
  location_id     UUID,                                 -- NULL = 창고 통합
  lot_id          UUID,                                 -- LOT 시 NOT NULL

  qty             NUMERIC(14, 4)  NOT NULL DEFAULT 0,
  reserved_qty    NUMERIC(14, 4)  NOT NULL DEFAULT 0,
  allocated_qty   NUMERIC(14, 4)  NOT NULL DEFAULT 0,

  received_at     TIMESTAMPTZ,                          -- FIFO/FEFO 정렬용 마지막 입고 시점
  version         INTEGER         NOT NULL DEFAULT 0,   -- 낙관락
  updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- NULL handling: COALESCE 패턴으로 NULL 도 unique 보장
  -- (PG 16+: NULLS NOT DISTINCT 옵션 사용 가능)
  CONSTRAINT uq_balances_key UNIQUE NULLS NOT DISTINCT (item_id, warehouse_id, location_id, lot_id),
  CONSTRAINT ck_balances_qty_nonneg     CHECK (qty >= 0 OR qty = 0),  -- 음수 허용 토글 OFF 시 별도 강제
  CONSTRAINT ck_balances_reserved       CHECK (reserved_qty >= 0),
  CONSTRAINT ck_balances_allocated      CHECK (allocated_qty >= 0),
  CONSTRAINT ck_balances_capacity       CHECK (qty >= reserved_qty + allocated_qty OR qty = 0),

  CONSTRAINT fk_balances_organization   FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_balances_item           FOREIGN KEY (item_id)         REFERENCES inventory_items(id) ON DELETE RESTRICT,
  CONSTRAINT fk_balances_warehouse      FOREIGN KEY (warehouse_id)    REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_balances_lot            FOREIGN KEY (lot_id)          REFERENCES inventory_lots(id) ON DELETE RESTRICT
);

CREATE INDEX idx_balances_item_wh   ON inventory_balances (item_id, warehouse_id);
CREATE INDEX idx_balances_with_qty  ON inventory_balances (organization_id, item_id) WHERE qty > 0;

COMMENT ON TABLE  inventory_balances              IS 'EI-200~299 재고 잔고. movement 합계 캐시. rules/stock_balance.md.';
COMMENT ON COLUMN inventory_balances.qty          IS 'EI-210 물리 재고. movement signed_qty 합계와 일치 (EI-260 검증).';
COMMENT ON COLUMN inventory_balances.reserved_qty IS '주문 / 작업지시 예약. inventory_reservations 합계와 일치 (EI-270).';
COMMENT ON COLUMN inventory_balances.allocated_qty IS '출고 직전 할당. specific lot/location 결정.';

-- ─── balance 스냅샷 (일별)
CREATE TABLE inventory_balance_snapshots (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  location_id     UUID,
  lot_id          UUID,
  snapshot_date   DATE NOT NULL,
  qty             NUMERIC(14, 4) NOT NULL,
  CONSTRAINT uq_balance_snap UNIQUE NULLS NOT DISTINCT (item_id, warehouse_id, location_id, lot_id, snapshot_date)
);

CREATE INDEX idx_balance_snap_date ON inventory_balance_snapshots (snapshot_date DESC, organization_id);
COMMENT ON TABLE inventory_balance_snapshots IS 'EI-211 일별 잔고 스냅샷. 회계 / 시점별 조회 / 감사용.';

-- ─── reservations
CREATE TYPE reservation_status AS ENUM ('ACTIVE', 'RELEASED', 'CONSUMED', 'EXPIRED');
CREATE TYPE reservation_source AS ENUM ('ORDER', 'WORK_ORDER', 'MANUAL');

CREATE TABLE inventory_reservations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  location_id     UUID,
  lot_id          UUID,
  qty             NUMERIC(14, 4) NOT NULL,
  source_type     reservation_source NOT NULL,
  source_id       VARCHAR(100) NOT NULL,
  status          reservation_status NOT NULL DEFAULT 'ACTIVE',
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  released_at     TIMESTAMPTZ,
  reason          TEXT,

  CONSTRAINT uq_reservations_source UNIQUE (organization_id, source_type, source_id),
  CONSTRAINT ck_reservations_qty    CHECK (qty > 0)
);

CREATE INDEX idx_reservations_active ON inventory_reservations (item_id, warehouse_id) WHERE status = 'ACTIVE';
CREATE INDEX idx_reservations_expiry ON inventory_reservations (expires_at) WHERE status = 'ACTIVE' AND expires_at IS NOT NULL;

COMMENT ON TABLE  inventory_reservations           IS 'EI-220 재고 예약. ORDER_CONFIRMED 등으로 사전 잠금. TTL 만료 자동 해제.';
COMMENT ON COLUMN inventory_reservations.expires_at IS 'EI-225 TTL. 도래 시 자동 EXPIRED + balance.reserved_qty 감소.';
