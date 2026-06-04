-- ════════════════════════════════════════════════════════════════════════
-- logistics_return_requests + logistics_return_lines — 반품
-- 룰 EL-500 ~ EL-599 / 상세: rules/returns.md
-- 게이트: logistics.return_handling
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE return_status        AS ENUM ('REQUESTED', 'APPROVED', 'REJECTED', 'PICKED_UP', 'RECEIVED', 'INSPECTED', 'COMPLETED', 'CANCELLED');
CREATE TYPE return_reason        AS ENUM ('CUSTOMER_REGRET', 'DEFECT', 'WRONG_ITEM', 'DAMAGED_TRANSIT', 'SYSTEM_ERROR');
CREATE TYPE return_request_source AS ENUM ('CUSTOMER', 'SYSTEM', 'OPERATOR');
CREATE TYPE return_cost_bearer   AS ENUM ('BUYER', 'SELLER', 'CARRIER');
CREATE TYPE return_inspection    AS ENUM ('PASS', 'PARTIAL', 'FAIL');
CREATE TYPE return_refund_status AS ENUM ('PENDING', 'ISSUED', 'DECLINED');

CREATE TABLE logistics_return_requests (
  id                    UUID                   PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       UUID                   NOT NULL,
  original_delivery_id  UUID                   NOT NULL,
  return_delivery_id    UUID,                   -- direction='RETURN' delivery (수거 시 생성)

  request_source        return_request_source  NOT NULL,
  reason                return_reason          NOT NULL,
  reason_detail         TEXT,

  status                return_status          NOT NULL DEFAULT 'REQUESTED',
  cost_bearer           return_cost_bearer,
  inspection_result     return_inspection,
  inspection_notes      TEXT,
  inspected_by          UUID,
  inspected_at          TIMESTAMPTZ,

  refund_status         return_refund_status,
  refund_amount         NUMERIC(14, 0),

  target_warehouse_id   UUID,                   -- 회수 창고 (RETURN type)

  requested_at          TIMESTAMPTZ            NOT NULL DEFAULT now(),
  approved_at           TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,

  CONSTRAINT uq_returns_original UNIQUE (organization_id, original_delivery_id),
  CONSTRAINT ck_returns_refund   CHECK (refund_amount IS NULL OR refund_amount >= 0),
  CONSTRAINT ck_returns_inspect  CHECK (
    (status IN ('INSPECTED', 'COMPLETED', 'REJECTED')) = (inspection_result IS NOT NULL OR status = 'REJECTED')
  ),
  CONSTRAINT fk_returns_org           FOREIGN KEY (organization_id)     REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_returns_original      FOREIGN KEY (original_delivery_id) REFERENCES logistics_deliveries(id) ON DELETE RESTRICT,
  CONSTRAINT fk_returns_return_dlv    FOREIGN KEY (return_delivery_id)   REFERENCES logistics_deliveries(id) ON DELETE RESTRICT,
  CONSTRAINT fk_returns_warehouse     FOREIGN KEY (target_warehouse_id) REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_returns_inspector     FOREIGN KEY (inspected_by)        REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_returns_org_status   ON logistics_return_requests (organization_id, status);
CREATE INDEX idx_returns_pending      ON logistics_return_requests (status, requested_at) WHERE status IN ('REQUESTED', 'APPROVED');

COMMENT ON TABLE  logistics_return_requests        IS 'EL-510 반품 요청. lifecycle EL-520. KR 전자상거래법 §17 청약철회.';
COMMENT ON COLUMN logistics_return_requests.reason IS 'EL-530 사유. cost_bearer 자동 분기 (EL-545).';

-- ─── return_lines
CREATE TABLE logistics_return_lines (
  id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  return_request_id   UUID            NOT NULL,
  delivery_line_id    UUID            NOT NULL,
  qty                 NUMERIC(14, 4)  NOT NULL,
  inspection_status   VARCHAR(20),                    -- PASS / DAMAGED / WRONG / MISSING
  notes               TEXT,

  CONSTRAINT uq_return_lines UNIQUE (return_request_id, delivery_line_id),
  CONSTRAINT ck_return_lines_qty CHECK (qty > 0),
  CONSTRAINT fk_return_lines_request FOREIGN KEY (return_request_id) REFERENCES logistics_return_requests(id) ON DELETE CASCADE,
  CONSTRAINT fk_return_lines_dline   FOREIGN KEY (delivery_line_id)  REFERENCES logistics_delivery_lines(id) ON DELETE RESTRICT
);

COMMENT ON TABLE logistics_return_lines IS 'EL-512 반품 라인. 부분 반품 표현 (qty ≤ 원 라인 qty).';
