-- ════════════════════════════════════════════════════════════════════════
-- inventory_cycle_counts + count_lines — 재고 실사
-- 룰 EI-500 ~ EI-599 / 상세: rules/cycle_count.md
-- 게이트: inventory.cycle_count
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE cycle_count_type   AS ENUM ('FULL', 'CYCLE', 'SPOT');
CREATE TYPE cycle_count_status AS ENUM ('DRAFT', 'COUNTING', 'RECONCILING', 'COMPLETED', 'CANCELLED');

CREATE TABLE inventory_cycle_counts (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID                NOT NULL,
  warehouse_id    UUID                NOT NULL,
  count_type      cycle_count_type    NOT NULL,
  status          cycle_count_status  NOT NULL DEFAULT 'DRAFT',
  scheduled_at    TIMESTAMPTZ,
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  scope           JSONB,                                  -- { categories, items, locations }
  count_round     SMALLINT            NOT NULL DEFAULT 1, -- 1차 / 2차 (EI-540)
  parent_count_id UUID,                                   -- 2차 카운트 시 1차 참조
  approved_by     UUID,
  created_by      UUID                NOT NULL,
  created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),

  CONSTRAINT ck_cycle_count_round CHECK (count_round >= 1 AND count_round <= 3),
  CONSTRAINT fk_cycle_count_org      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_cycle_count_wh       FOREIGN KEY (warehouse_id)    REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_cycle_count_parent   FOREIGN KEY (parent_count_id) REFERENCES inventory_cycle_counts(id) ON DELETE RESTRICT,
  CONSTRAINT fk_cycle_count_creator  FOREIGN KEY (created_by)      REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_cycle_count_status ON inventory_cycle_counts (organization_id, status);

COMMENT ON TABLE inventory_cycle_counts IS 'EI-500 재고 실사. 3모드 (FULL/CYCLE/SPOT). 차이>5% 시 2차 카운트 의무 (EI-540).';

CREATE TABLE inventory_count_lines (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_count_id  UUID            NOT NULL,
  item_id         UUID            NOT NULL,
  warehouse_id    UUID            NOT NULL,
  location_id     UUID,
  lot_id          UUID,
  expected_qty    NUMERIC(14, 4)  NOT NULL,
  counted_qty     NUMERIC(14, 4),                        -- NULL = 미카운트
  diff_qty        NUMERIC(14, 4)  GENERATED ALWAYS AS (counted_qty - expected_qty) STORED,
  counted_by      UUID,
  counted_at      TIMESTAMPTZ,
  reconciled_at   TIMESTAMPTZ,
  reconciled_by   UUID,
  reason          TEXT,

  CONSTRAINT uq_count_lines_unique UNIQUE NULLS NOT DISTINCT (cycle_count_id, item_id, warehouse_id, location_id, lot_id),
  CONSTRAINT fk_count_lines_count   FOREIGN KEY (cycle_count_id) REFERENCES inventory_cycle_counts(id) ON DELETE CASCADE,
  CONSTRAINT fk_count_lines_item    FOREIGN KEY (item_id)        REFERENCES inventory_items(id) ON DELETE RESTRICT
);

CREATE INDEX idx_count_lines_pending ON inventory_count_lines (cycle_count_id) WHERE counted_qty IS NULL;
CREATE INDEX idx_count_lines_diff    ON inventory_count_lines (cycle_count_id) WHERE diff_qty IS NOT NULL AND diff_qty <> 0;

COMMENT ON TABLE  inventory_count_lines              IS 'EI-520 실사 라인. expected_qty 는 카운트 시작 시점 시스템 잔고 스냅샷.';
COMMENT ON COLUMN inventory_count_lines.diff_qty     IS '계산 컬럼 (counted - expected). 차이>5% 면 2차 카운트 트리거 (EI-540).';
