-- ════════════════════════════════════════════════════════════════════════
-- logistics_deliveries + delivery_lines — 배송 lifecycle
-- 룰 EL-001 ~ EL-099 / 상세: rules/delivery.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE delivery_direction AS ENUM ('OUTBOUND', 'RETURN');
CREATE TYPE delivery_type      AS ENUM ('STANDARD', 'EXPRESS', 'SAME_DAY', 'SCHEDULED');
CREATE TYPE delivery_status    AS ENUM ('DRAFT', 'ASSIGNED', 'IN_TRANSIT', 'DELIVERED', 'FAILED', 'CANCELLED');

CREATE TABLE logistics_deliveries (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID                NOT NULL,
  facility_id     UUID,
  warehouse_id    UUID,
  order_id        VARCHAR(100),
  order_line_no   SMALLINT,
  parent_delivery_id UUID,                                -- RETURN delivery 의 원 delivery
  route_id        UUID,

  direction       delivery_direction  NOT NULL DEFAULT 'OUTBOUND',
  delivery_type   delivery_type       NOT NULL DEFAULT 'STANDARD',
  carrier         VARCHAR(20)         NOT NULL DEFAULT 'self',

  -- PII (마스킹 대상 EL-070)
  recipient_name      VARCHAR(100)    NOT NULL,
  recipient_phone     VARCHAR(20)     NOT NULL,
  recipient_address   TEXT            NOT NULL,
  recipient_postal    VARCHAR(10),

  -- 시간
  scheduled_at        TIMESTAMPTZ,
  dispatched_at       TIMESTAMPTZ,
  expected_eta        TIMESTAMPTZ,
  completed_at        TIMESTAMPTZ,

  -- 배차
  driver_id           UUID,
  vehicle_id          UUID,

  -- 상태
  status              delivery_status NOT NULL DEFAULT 'DRAFT',
  attempt_count       SMALLINT        NOT NULL DEFAULT 0,
  cancel_reason       TEXT,
  fail_reason         TEXT,

  -- 외부
  tracking_no         VARCHAR(50),

  -- 운임 (EL-425)
  shipping_cost       NUMERIC(14, 0),
  tariff_id           UUID,
  cost_breakdown      JSONB,
  distance_km         NUMERIC(10, 3),

  meta                JSONB,
  created_by          UUID            NOT NULL,
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ,

  -- ─── 제약 ───────────────────────────────────────────
  -- 멱등 (EL-030)
  CONSTRAINT uq_deliveries_order_line  UNIQUE (organization_id, order_id, order_line_no),
  CONSTRAINT ck_deliveries_carrier     CHECK (carrier ~ '^[a-z][a-z0-9_]*$'),
  CONSTRAINT ck_deliveries_attempt     CHECK (attempt_count >= 0),
  CONSTRAINT ck_deliveries_completed   CHECK (
    (status = 'DELIVERED' AND completed_at IS NOT NULL) OR status <> 'DELIVERED'
  ),
  CONSTRAINT ck_deliveries_assigned    CHECK (
    (status NOT IN ('DRAFT', 'CANCELLED')) = (driver_id IS NOT NULL OR carrier <> 'self')
  ),
  CONSTRAINT fk_deliveries_org         FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_warehouse   FOREIGN KEY (warehouse_id)    REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_driver      FOREIGN KEY (driver_id)       REFERENCES logistics_drivers(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_vehicle     FOREIGN KEY (vehicle_id)      REFERENCES logistics_vehicles(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_route       FOREIGN KEY (route_id)        REFERENCES logistics_routes(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_parent      FOREIGN KEY (parent_delivery_id) REFERENCES logistics_deliveries(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_creator     FOREIGN KEY (created_by)      REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_deliveries_org_status      ON logistics_deliveries (organization_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_deliveries_driver          ON logistics_deliveries (driver_id, status) WHERE driver_id IS NOT NULL;
CREATE INDEX idx_deliveries_route           ON logistics_deliveries (route_id) WHERE route_id IS NOT NULL;
CREATE INDEX idx_deliveries_scheduled       ON logistics_deliveries (scheduled_at) WHERE status IN ('DRAFT', 'ASSIGNED');
CREATE INDEX idx_deliveries_in_transit      ON logistics_deliveries (organization_id, dispatched_at) WHERE status = 'IN_TRANSIT';
CREATE INDEX idx_deliveries_tracking_no     ON logistics_deliveries (tracking_no) WHERE tracking_no IS NOT NULL;

COMMENT ON TABLE  logistics_deliveries          IS 'EL-010 배송 사실 + lifecycle. 단방향 상태 머신. rules/delivery.md.';
COMMENT ON COLUMN logistics_deliveries.recipient_name    IS 'PII (EL-070). UI 표시 시 마스킹 강제.';
COMMENT ON COLUMN logistics_deliveries.recipient_phone   IS 'PII (EL-070). 010-****-1234 형태 마스킹.';
COMMENT ON COLUMN logistics_deliveries.recipient_address IS 'PII (EL-070). 상세주소 마스킹. 보존 5년 (전자상거래법).';
COMMENT ON COLUMN logistics_deliveries.status            IS 'EL-020 단방향 머신: DRAFT→ASSIGNED→IN_TRANSIT→DELIVERED/FAILED/CANCELLED.';

-- ─── delivery_lines
CREATE TABLE logistics_delivery_lines (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id     UUID            NOT NULL,
  item_id         UUID            NOT NULL,
  lot_id          UUID,
  serial_id       UUID,
  qty             NUMERIC(14, 4)  NOT NULL,
  unit_price      NUMERIC(14, 0),
  meta            JSONB,
  CONSTRAINT uq_delivery_lines UNIQUE NULLS NOT DISTINCT (delivery_id, item_id, lot_id, serial_id),
  CONSTRAINT ck_delivery_lines_qty CHECK (qty > 0),
  CONSTRAINT fk_delivery_lines_delivery FOREIGN KEY (delivery_id) REFERENCES logistics_deliveries(id) ON DELETE CASCADE,
  CONSTRAINT fk_delivery_lines_item     FOREIGN KEY (item_id)     REFERENCES inventory_items(id) ON DELETE RESTRICT
);

CREATE INDEX idx_delivery_lines_item ON logistics_delivery_lines (item_id);
COMMENT ON TABLE logistics_delivery_lines IS 'EL-015 배송 품목 라인. inventory item / lot / serial 정합.';
