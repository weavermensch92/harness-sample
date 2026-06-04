-- ════════════════════════════════════════════════════════════════════════
-- inventory_cost_layers + inventory_avg_costs — 원가 평가
-- 룰 EI-600 ~ EI-699 / 상세: rules/valuation.md
-- 게이트: inventory.valuation_fifo / inventory.valuation_moving_avg (상호 배타)
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE cost_layer_status AS ENUM ('ACTIVE', 'DEPLETED');

CREATE TABLE inventory_cost_layers (
  id              UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID              NOT NULL,
  item_id         UUID              NOT NULL,
  warehouse_id    UUID              NOT NULL,
  in_movement_id  UUID              NOT NULL,                -- 입고 movement
  received_at     TIMESTAMPTZ       NOT NULL,
  initial_qty     NUMERIC(14, 4)    NOT NULL,
  remaining_qty   NUMERIC(14, 4)    NOT NULL,
  unit_cost       NUMERIC(14, 0)    NOT NULL,                -- 입고 단가 (KRW)
  status          cost_layer_status NOT NULL DEFAULT 'ACTIVE',
  created_at      TIMESTAMPTZ       NOT NULL DEFAULT now(),

  CONSTRAINT uq_cost_layers_in_movement UNIQUE (in_movement_id),
  CONSTRAINT ck_cost_layers_qty         CHECK (initial_qty > 0 AND remaining_qty >= 0 AND remaining_qty <= initial_qty),
  CONSTRAINT ck_cost_layers_unit_cost   CHECK (unit_cost >= 0),
  CONSTRAINT ck_cost_layers_status      CHECK (
    (status = 'DEPLETED' AND remaining_qty = 0) OR
    (status = 'ACTIVE'   AND remaining_qty > 0)
  ),
  CONSTRAINT fk_cost_layers_org      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_cost_layers_item     FOREIGN KEY (item_id)         REFERENCES inventory_items(id) ON DELETE RESTRICT,
  CONSTRAINT fk_cost_layers_movement FOREIGN KEY (in_movement_id)  REFERENCES inventory_movements(id) ON DELETE RESTRICT
);

-- FIFO 정렬 인덱스 (EI-615)
CREATE INDEX idx_cost_layers_fifo ON inventory_cost_layers (item_id, warehouse_id, received_at ASC) WHERE status = 'ACTIVE';

COMMENT ON TABLE  inventory_cost_layers          IS 'EI-610 FIFO 레이어. 각 IN movement = 1 레이어. 출고 시 received_at 빠른 순 차감.';
COMMENT ON COLUMN inventory_cost_layers.unit_cost IS 'EI-610 입고 단가 (KRW/base_uom). 부대비용 포함.';

-- ─── 이동평균 (Moving Average)
CREATE TABLE inventory_avg_costs (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID            NOT NULL,
  item_id         UUID            NOT NULL,
  warehouse_id    UUID            NOT NULL,
  current_qty     NUMERIC(14, 4)  NOT NULL DEFAULT 0,
  current_avg_cost NUMERIC(14, 4) NOT NULL DEFAULT 0,    -- 정밀도 보존
  last_updated_at TIMESTAMPTZ     NOT NULL DEFAULT now(),

  CONSTRAINT uq_avg_costs_item_wh UNIQUE (item_id, warehouse_id),
  CONSTRAINT ck_avg_costs_nonneg  CHECK (current_qty >= 0 AND current_avg_cost >= 0),
  CONSTRAINT fk_avg_costs_org     FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_avg_costs_item    FOREIGN KEY (item_id)         REFERENCES inventory_items(id) ON DELETE RESTRICT
);

COMMENT ON TABLE  inventory_avg_costs                  IS 'EI-620 이동평균 단가. IN 시 (old_avg×old_qty + new_cost×new_qty)/(old+new) 갱신.';
COMMENT ON COLUMN inventory_avg_costs.current_avg_cost IS 'NUMERIC(14, 4) — 정밀도 보존. 표시 시 0~2 자리 반올림.';
