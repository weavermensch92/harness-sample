-- ════════════════════════════════════════════════════════════════════════
-- inventory_items — 품목 마스터
-- 룰 EI-001 ~ EI-099 / 상세: rules/item_master.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE item_status     AS ENUM ('DRAFT', 'ACTIVE', 'DISCONTINUED');
CREATE TYPE item_tracking   AS ENUM ('NONE', 'LOT', 'SERIAL');

CREATE TABLE inventory_items (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID            NOT NULL,
  sku             VARCHAR(50)     NOT NULL,
  name            VARCHAR(300)    NOT NULL,
  category_id     UUID,                                 -- leaf 카테고리
  base_uom        VARCHAR(10)     NOT NULL,             -- EA / KG / L / M / BOX 등
  barcode         VARCHAR(20),                          -- UPC/EAN/KAN
  external_code   VARCHAR(100),                         -- 외부 시스템 매핑
  tracking_mode   item_tracking   NOT NULL DEFAULT 'NONE',
  status          item_status     NOT NULL DEFAULT 'DRAFT',
  reference_price NUMERIC(14, 0),                       -- 참조 단가 (KRW)
  -- 물리 속성 (v0.2: logistics 적재 / 운임 정합, EI-024)
  weight          NUMERIC(10, 2),                       -- weight_uom 단위
  weight_uom      VARCHAR(10),                          -- kg / g / lb / oz / t
  volume          NUMERIC(10, 2),                       -- volume_uom 단위
  volume_uom      VARCHAR(10),                          -- m3 / l / ml / cm3
  dim_length_cm   NUMERIC(10, 2),                       -- 가로 (cm)
  dim_width_cm    NUMERIC(10, 2),                       -- 세로 (cm)
  dim_height_cm   NUMERIC(10, 2),                       -- 높이 (cm)
  meta            JSONB,
  created_by      UUID            NOT NULL,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,                          -- soft delete

  CONSTRAINT uq_items_org_sku       UNIQUE (organization_id, sku),
  CONSTRAINT uq_items_org_barcode   UNIQUE (organization_id, barcode),
  CONSTRAINT ck_items_sku_format    CHECK (sku ~ '^[A-Z0-9][A-Z0-9-]{3,49}$'),
  CONSTRAINT ck_items_ref_price     CHECK (reference_price IS NULL OR reference_price >= 0),
  -- v0.2 물리 속성 검증
  CONSTRAINT ck_items_weight_positive CHECK (weight IS NULL OR weight > 0),
  CONSTRAINT ck_items_volume_positive CHECK (volume IS NULL OR volume > 0),
  CONSTRAINT ck_items_weight_pair     CHECK ((weight IS NULL) = (weight_uom IS NULL)),
  CONSTRAINT ck_items_volume_pair     CHECK ((volume IS NULL) = (volume_uom IS NULL)),
  CONSTRAINT ck_items_weight_uom      CHECK (weight_uom IS NULL OR weight_uom IN ('kg','g','lb','oz','t')),
  CONSTRAINT ck_items_volume_uom      CHECK (volume_uom IS NULL OR volume_uom IN ('m3','l','ml','cm3')),
  CONSTRAINT ck_items_dim_length      CHECK (dim_length_cm IS NULL OR dim_length_cm > 0),
  CONSTRAINT ck_items_dim_width       CHECK (dim_width_cm  IS NULL OR dim_width_cm  > 0),
  CONSTRAINT ck_items_dim_height      CHECK (dim_height_cm IS NULL OR dim_height_cm > 0),
  CONSTRAINT fk_items_organization  FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_items_category      FOREIGN KEY (category_id)     REFERENCES inventory_categories(id) ON DELETE RESTRICT,
  CONSTRAINT fk_items_creator       FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

CREATE INDEX idx_items_org_active      ON inventory_items (organization_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_items_category        ON inventory_items (category_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_items_tracking        ON inventory_items (organization_id, tracking_mode) WHERE deleted_at IS NULL;

COMMENT ON TABLE  inventory_items                IS 'EI-001~099 품목 마스터. SKU 변경 금지, soft delete. rules/item_master.md.';
COMMENT ON COLUMN inventory_items.sku            IS 'EI-010 사업장 단위 unique. UPPER-DIGIT-DASH 4~50자.';
COMMENT ON COLUMN inventory_items.base_uom       IS 'EI-020 기준 단위. 모든 movement / balance 는 이 단위. 변경 금지 (EI-025).';
COMMENT ON COLUMN inventory_items.tracking_mode  IS 'EI-050 NONE / LOT / SERIAL. 게이트 토글 inventory.lot_tracking / serial_tracking.';
COMMENT ON COLUMN inventory_items.reference_price IS 'EI-070 참조 단가 (KRW). 실 평가 단가는 inventory_cost_layers / avg_costs 사용.';
COMMENT ON COLUMN inventory_items.weight         IS 'EI-024 (v0.2) 단일 단위 무게. 단위는 weight_uom. logistics EL-160 적재 검증 / EL-420 운임.';
COMMENT ON COLUMN inventory_items.volume         IS 'EI-024 (v0.2) 단일 단위 부피. 단위는 volume_uom.';
COMMENT ON COLUMN inventory_items.dim_length_cm  IS 'EI-024 (v0.2) 가로 (cm). 운송 적재 모델링 (Phase 1+).';

-- 카테고리 테이블 (item_master.md EI-030)
CREATE TABLE inventory_categories (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID         NOT NULL,
  parent_id       UUID,
  code            VARCHAR(50)  NOT NULL,
  name            VARCHAR(200) NOT NULL,
  depth           SMALLINT     NOT NULL,
  is_leaf         BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,

  CONSTRAINT uq_categories_org_code UNIQUE (organization_id, code),
  CONSTRAINT ck_categories_depth    CHECK (depth >= 1 AND depth <= 5),
  CONSTRAINT ck_categories_root     CHECK (
    (parent_id IS NULL AND depth = 1) OR (parent_id IS NOT NULL AND depth >= 2)
  ),
  CONSTRAINT fk_categories_parent       FOREIGN KEY (parent_id) REFERENCES inventory_categories(id) ON DELETE RESTRICT,
  CONSTRAINT fk_categories_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT
);

CREATE INDEX idx_categories_parent ON inventory_categories (parent_id) WHERE deleted_at IS NULL;
COMMENT ON TABLE  inventory_categories      IS 'EI-030 품목 카테고리 트리. 깊이 ≤5. 품목은 leaf 만.';

-- UOM 변환 (item_master.md EI-021)
CREATE TABLE inventory_uom_conversions (
  item_id      UUID NOT NULL,
  display_uom  VARCHAR(10) NOT NULL,
  base_uom     VARCHAR(10) NOT NULL,
  factor       NUMERIC(14, 6) NOT NULL,           -- 1 display_uom = factor base_uom
  PRIMARY KEY (item_id, display_uom),
  CONSTRAINT ck_uom_factor_positive CHECK (factor > 0),
  CONSTRAINT fk_uom_item FOREIGN KEY (item_id) REFERENCES inventory_items(id) ON DELETE CASCADE
);

COMMENT ON TABLE inventory_uom_conversions IS 'EI-021 단위 변환. 1 display_uom = factor base_uom.';
