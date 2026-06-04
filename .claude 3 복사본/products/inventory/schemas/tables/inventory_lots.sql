-- ════════════════════════════════════════════════════════════════════════
-- inventory_lots + inventory_serials — 로트 / 시리얼 추적
-- 룰 EI-300 ~ EI-399 / 상세: rules/lot_tracking.md
-- 게이트: inventory.lot_tracking / inventory.serial_tracking
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE lot_status    AS ENUM ('ACTIVE', 'QUARANTINED', 'EXPIRED', 'DISPOSED');
CREATE TYPE serial_status AS ENUM ('IN_STOCK', 'SHIPPED', 'RETURNED', 'SCRAPPED');

CREATE TABLE inventory_lots (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID         NOT NULL,
  item_id         UUID         NOT NULL,
  lot_no          VARCHAR(50)  NOT NULL,                -- 제조번호 / 배치번호
  manufactured_at DATE,
  expires_at      DATE,                                  -- 유통기한 / 사용기한
  supplier_lot    VARCHAR(50),
  meta            JSONB,
  status          lot_status   NOT NULL DEFAULT 'ACTIVE',
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

  CONSTRAINT uq_lots_org_item_no    UNIQUE (organization_id, item_id, lot_no),
  CONSTRAINT ck_lots_no_format      CHECK (lot_no ~ '^[A-Z0-9][A-Z0-9_-]{0,49}$'),
  CONSTRAINT ck_lots_dates          CHECK (
    manufactured_at IS NULL OR expires_at IS NULL OR expires_at >= manufactured_at
  ),
  CONSTRAINT fk_lots_organization   FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_lots_item           FOREIGN KEY (item_id)         REFERENCES inventory_items(id) ON DELETE RESTRICT
);

CREATE INDEX idx_lots_item_active  ON inventory_lots (item_id, status) WHERE status IN ('ACTIVE', 'QUARANTINED');
CREATE INDEX idx_lots_expiry       ON inventory_lots (expires_at) WHERE status = 'ACTIVE' AND expires_at IS NOT NULL;
CREATE INDEX idx_lots_org_status   ON inventory_lots (organization_id, status);

COMMENT ON TABLE  inventory_lots                IS 'EI-300~ 로트 / 배치 / 유통기한 추적. KR 식품·의약품·화장품 의무. rules/lot_tracking.md.';
COMMENT ON COLUMN inventory_lots.lot_no         IS 'EI-310 제조번호. 사업장+품목 단위 unique. 외부 공급사 lot 그대로 권장.';
COMMENT ON COLUMN inventory_lots.expires_at     IS 'EI-340 유통기한 / 사용기한. inventory.expiry_block_ship 토글로 만료 출고 차단.';

-- ─── serials
CREATE TABLE inventory_serials (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID          NOT NULL,
  item_id             UUID          NOT NULL,
  lot_id              UUID,
  serial_no           VARCHAR(100)  NOT NULL,
  current_warehouse_id UUID,
  current_location_id UUID,
  status              serial_status NOT NULL DEFAULT 'IN_STOCK',
  meta                JSONB,
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT uq_serials_org_item_no UNIQUE (organization_id, item_id, serial_no),
  CONSTRAINT fk_serials_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_serials_item         FOREIGN KEY (item_id)         REFERENCES inventory_items(id) ON DELETE RESTRICT,
  CONSTRAINT fk_serials_lot          FOREIGN KEY (lot_id)          REFERENCES inventory_lots(id) ON DELETE RESTRICT
);

CREATE INDEX idx_serials_item_status ON inventory_serials (item_id, status);
CREATE INDEX idx_serials_lot         ON inventory_serials (lot_id) WHERE lot_id IS NOT NULL;

COMMENT ON TABLE inventory_serials IS 'EI-320 시리얼 단위 추적 (가전 / 의료기기 / 고가 자산). 게이트: inventory.serial_tracking.';
