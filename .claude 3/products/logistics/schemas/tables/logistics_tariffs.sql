-- ════════════════════════════════════════════════════════════════════════
-- logistics_tariffs + logistics_region_surcharges — 운임 단가
-- 룰 EL-400 ~ EL-499 / 상세: rules/shipping_cost.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE logistics_tariffs (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID            NOT NULL,
  carrier         VARCHAR(20)     NOT NULL,
  tariff_code     VARCHAR(50)     NOT NULL,
  -- 적용 조건
  weight_min_kg   NUMERIC(10, 3),
  weight_max_kg   NUMERIC(10, 3),
  volume_min_m3   NUMERIC(10, 3),
  volume_max_m3   NUMERIC(10, 3),
  region          VARCHAR(20),                          -- METROPOLITAN / RURAL / ISLAND / NULL
  delivery_type   VARCHAR(20),                          -- STANDARD / EXPRESS / SAME_DAY / NULL
  -- 단가
  base_price      NUMERIC(14, 0)  NOT NULL,
  per_km_price    NUMERIC(14, 0),
  -- 시점
  effective_from  DATE            NOT NULL,
  effective_to    DATE,
  notes           TEXT,
  created_by      UUID            NOT NULL,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  CONSTRAINT uq_tariffs_unique UNIQUE (organization_id, carrier, tariff_code, effective_from),
  CONSTRAINT ck_tariffs_base   CHECK (base_price >= 0),
  CONSTRAINT ck_tariffs_per_km CHECK (per_km_price IS NULL OR per_km_price >= 0),
  CONSTRAINT ck_tariffs_weight CHECK (
    weight_min_kg IS NULL OR weight_max_kg IS NULL OR weight_max_kg >= weight_min_kg
  ),
  CONSTRAINT ck_tariffs_effective CHECK (effective_to IS NULL OR effective_to >= effective_from),
  CONSTRAINT fk_tariffs_org    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_tariffs_creator FOREIGN KEY (created_by)     REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_tariffs_lookup ON logistics_tariffs (organization_id, carrier, effective_from DESC);
CREATE INDEX idx_tariffs_active ON logistics_tariffs (organization_id, carrier) WHERE effective_to IS NULL;

COMMENT ON TABLE  logistics_tariffs IS 'EL-410 운임 단가표. 시점별 이력 (UPDATE 금지, 새 row).';

-- ─── region surcharges (도서산간)
CREATE TABLE logistics_region_surcharges (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID            NOT NULL,
  carrier         VARCHAR(20)     NOT NULL,
  postal_pattern  VARCHAR(20)     NOT NULL,           -- '63%' 또는 '63000'
  region_label    VARCHAR(50)     NOT NULL,           -- '제주' / '울릉도' / '도서' / '산간'
  surcharge       NUMERIC(14, 0)  NOT NULL,
  effective_from  DATE            NOT NULL,
  effective_to    DATE,

  CONSTRAINT uq_region_surcharges UNIQUE (organization_id, carrier, postal_pattern, effective_from),
  CONSTRAINT ck_region_surcharges_amount CHECK (surcharge >= 0),
  CONSTRAINT fk_region_surcharges_org    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT
);

CREATE INDEX idx_region_surcharges_active ON logistics_region_surcharges (organization_id, carrier) WHERE effective_to IS NULL;

COMMENT ON TABLE  logistics_region_surcharges IS 'EL-430 도서산간 가산. postal_pattern 매칭.';
COMMENT ON COLUMN logistics_region_surcharges.postal_pattern IS '예: ''63%'' (prefix), ''63000'' (정확). EL-435 매칭 로직.';
