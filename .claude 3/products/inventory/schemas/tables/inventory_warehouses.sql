-- ════════════════════════════════════════════════════════════════════════
-- inventory_warehouses + inventory_locations
-- 룰 EI-400 ~ EI-499 / 상세: rules/warehouse.md
-- 게이트: inventory.multi_warehouse / inventory.location_bin
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE warehouse_type   AS ENUM ('MAIN', 'COLD', 'DISTRIBUTION', 'RETURN', 'QUARANTINE');
CREATE TYPE warehouse_status AS ENUM ('ACTIVE', 'INACTIVE', 'FROZEN');
CREATE TYPE location_type    AS ENUM ('ZONE', 'AISLE', 'RACK', 'BIN');

CREATE TABLE inventory_warehouses (
  id              UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID             NOT NULL,
  facility_id     UUID,
  code            VARCHAR(20)      NOT NULL,
  name            VARCHAR(200)     NOT NULL,
  warehouse_type  warehouse_type   NOT NULL DEFAULT 'MAIN',
  address         TEXT,
  status          warehouse_status NOT NULL DEFAULT 'ACTIVE',
  meta            JSONB,                                  -- 온도조건, 보안등급
  created_at      TIMESTAMPTZ      NOT NULL DEFAULT now(),

  CONSTRAINT uq_warehouses_org_code  UNIQUE (organization_id, code),
  CONSTRAINT ck_warehouses_code      CHECK (code ~ '^[A-Z][A-Z0-9-]*$'),
  CONSTRAINT fk_warehouses_org       FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_warehouses_facility  FOREIGN KEY (facility_id)     REFERENCES facilities(id)    ON DELETE RESTRICT
);

CREATE INDEX idx_warehouses_org_active ON inventory_warehouses (organization_id, status);

COMMENT ON TABLE  inventory_warehouses        IS 'EI-410 물리/논리 창고. 게이트: inventory.multi_warehouse OFF 시 1개만.';
COMMENT ON COLUMN inventory_warehouses.status IS 'EI-430 ACTIVE/INACTIVE/FROZEN. FROZEN 시 입출고 차단 (실사 / 감사).';

-- ─── locations
CREATE TABLE inventory_locations (
  id              UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID             NOT NULL,
  warehouse_id    UUID             NOT NULL,
  parent_id       UUID,                                   -- self-FK
  code            VARCHAR(50)      NOT NULL,
  name            VARCHAR(200),
  location_type   location_type    NOT NULL,
  depth           SMALLINT         NOT NULL,              -- 1=ZONE / 2=AISLE / 3=RACK / 4=BIN
  status          warehouse_status NOT NULL DEFAULT 'ACTIVE',
  capacity        NUMERIC(14, 4),
  meta            JSONB,
  created_at      TIMESTAMPTZ      NOT NULL DEFAULT now(),

  CONSTRAINT uq_locations_wh_code UNIQUE (warehouse_id, code),
  CONSTRAINT ck_locations_depth   CHECK (depth >= 1 AND depth <= 4),
  CONSTRAINT ck_locations_root    CHECK (
    (parent_id IS NULL AND depth = 1) OR (parent_id IS NOT NULL AND depth >= 2)
  ),
  CONSTRAINT fk_locations_org     FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_locations_wh      FOREIGN KEY (warehouse_id)    REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_locations_parent  FOREIGN KEY (parent_id)       REFERENCES inventory_locations(id)  ON DELETE RESTRICT
);

CREATE INDEX idx_locations_wh_active ON inventory_locations (warehouse_id, status);
CREATE INDEX idx_locations_parent    ON inventory_locations (parent_id) WHERE parent_id IS NOT NULL;

COMMENT ON TABLE  inventory_locations          IS 'EI-420 창고 내부 위치 트리. 깊이 1~4. 게이트: inventory.location_bin OFF 시 NULL.';
COMMENT ON COLUMN inventory_locations.depth    IS 'EI-425 1=ZONE / 2=AISLE / 3=RACK / 4=BIN.';
