-- ════════════════════════════════════════════════════════════════════════
-- inventory_movements — 재고 이동 (사실 기록, append-only)
-- 룰 EI-100 ~ EI-199 / 상세: rules/stock_movement.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE movement_direction AS ENUM ('IN', 'OUT', 'TRANSFER', 'ADJUSTMENT');
CREATE TYPE movement_status    AS ENUM ('ACTIVE', 'CANCELLED');
CREATE TYPE movement_source    AS ENUM (
  'PURCHASE',
  'ORDER',
  'DELIVERY',
  'MANUAL',
  'COUNT_ADJUSTMENT',
  'REVERSAL',
  'TRANSFER_INTERNAL',
  'EXPIRY_DISPOSAL',
  'RETURN'              -- v0.2: logistics 반품 정합 (EL-550). source_id='rtn:{rr_id}:{rl_id}'
);

CREATE TABLE inventory_movements (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID                NOT NULL,
  facility_id     UUID,
  warehouse_id    UUID                NOT NULL,
  location_id     UUID,
  item_id         UUID                NOT NULL,
  lot_id          UUID,                                 -- LOT/SERIAL 모드 시 필수
  serial_id       UUID,                                 -- SERIAL 모드 시 필수

  direction       movement_direction  NOT NULL,
  qty             NUMERIC(14, 4)      NOT NULL,         -- 항상 양수
  signed_qty      NUMERIC(14, 4)      NOT NULL,         -- balance 갱신용 (+/-)

  -- TRANSFER 짝
  to_warehouse_id UUID,
  to_location_id  UUID,
  paired_id       UUID,                                  -- 같은 transfer 짝 식별

  -- 출처 (멱등 EI-110)
  source_type     movement_source     NOT NULL,
  source_id       VARCHAR(100)        NOT NULL,

  status          movement_status     NOT NULL DEFAULT 'ACTIVE',

  -- 평가
  unit_cost       NUMERIC(14, 0),
  total_cost      NUMERIC(14, 0),

  reason          TEXT,
  reference       TEXT,
  meta            JSONB,
  created_by      UUID                NOT NULL,
  created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),
  occurred_at     TIMESTAMPTZ         NOT NULL,

  -- ─── 제약 ───────────────────────────────────────────
  CONSTRAINT uq_movements_source          UNIQUE (organization_id, source_type, source_id),
  CONSTRAINT ck_movements_qty_positive    CHECK (qty > 0),
  CONSTRAINT ck_movements_signed_qty      CHECK (
    (direction = 'IN'         AND signed_qty = qty) OR
    (direction = 'OUT'        AND signed_qty = -qty) OR
    (direction = 'ADJUSTMENT' AND ABS(signed_qty) = qty) OR
    (direction = 'TRANSFER')
  ),
  CONSTRAINT ck_movements_total_cost      CHECK (
    total_cost IS NULL OR unit_cost IS NULL OR
    ABS(total_cost - ROUND(qty * unit_cost)) <= 1   -- 1원 반올림 오차 허용
  ),
  CONSTRAINT ck_movements_transfer_to     CHECK (
    direction <> 'TRANSFER' OR (to_warehouse_id IS NOT NULL OR to_location_id IS NOT NULL)
  ),
  CONSTRAINT fk_movements_organization    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_movements_warehouse       FOREIGN KEY (warehouse_id)    REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_movements_item            FOREIGN KEY (item_id)         REFERENCES inventory_items(id)     ON DELETE RESTRICT,
  CONSTRAINT fk_movements_lot             FOREIGN KEY (lot_id)          REFERENCES inventory_lots(id)      ON DELETE RESTRICT,
  CONSTRAINT fk_movements_creator         FOREIGN KEY (created_by)      REFERENCES users(id)               ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
CREATE INDEX idx_movements_item_wh_time ON inventory_movements (item_id, warehouse_id, occurred_at DESC);
CREATE INDEX idx_movements_org_time     ON inventory_movements (organization_id, occurred_at DESC);
CREATE INDEX idx_movements_status_active ON inventory_movements (organization_id) WHERE status = 'ACTIVE';
CREATE INDEX idx_movements_paired       ON inventory_movements (paired_id) WHERE paired_id IS NOT NULL;
CREATE INDEX idx_movements_lot          ON inventory_movements (lot_id) WHERE lot_id IS NOT NULL;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  inventory_movements             IS 'EI-100~199 재고 이동 사실. append-only. 정정은 REVERSAL row. rules/stock_movement.md.';
COMMENT ON COLUMN inventory_movements.qty         IS '항상 양수. balance 갱신은 signed_qty.';
COMMENT ON COLUMN inventory_movements.signed_qty  IS 'EI-121 balance 갱신용 부호 포함 수량.';
COMMENT ON COLUMN inventory_movements.source_id   IS 'EI-110 멱등 키. PURCHASE=po:..., DELIVERY=dlv:..., MANUAL=man:..., REVERSAL=rev:...';
COMMENT ON COLUMN inventory_movements.status      IS 'EI-155 ACTIVE/CANCELLED. CANCELLED 은 표시만, 잔고 영향 X (정정은 REVERSAL).';
COMMENT ON COLUMN inventory_movements.paired_id   IS 'EI-125 TRANSFER 짝 식별 (OUT + IN 양쪽 같은 paired_id).';
