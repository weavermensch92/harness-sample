-- ════════════════════════════════════════════════════════════════════════
-- logistics_drivers + logistics_vehicles
-- 룰 EL-100 ~ EL-199 / 상세: rules/driver_vehicle.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE driver_status   AS ENUM ('ACTIVE', 'SUSPENDED', 'TERMINATED');
CREATE TYPE vehicle_status  AS ENUM ('ACTIVE', 'MAINTENANCE', 'RETIRED');

CREATE TABLE logistics_drivers (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID          NOT NULL,
  user_id             UUID          NOT NULL,
  driver_code         VARCHAR(20)   NOT NULL,
  license_no          VARCHAR(30)   NOT NULL,
  license_type        VARCHAR(20)   NOT NULL,           -- '1종보통' / '1종대형' / '2종' / '특수'
  license_expires_at  DATE          NOT NULL,
  hazmat_cert         BOOLEAN       NOT NULL DEFAULT FALSE,
  hazmat_expires_at   DATE,
  -- PII 동의 (EL-080)
  location_consent    BOOLEAN       NOT NULL DEFAULT FALSE,
  location_consent_at TIMESTAMPTZ,
  status              driver_status NOT NULL DEFAULT 'ACTIVE',
  notes               TEXT,
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT uq_drivers_org_code  UNIQUE (organization_id, driver_code),
  CONSTRAINT uq_drivers_org_user  UNIQUE (organization_id, user_id),
  CONSTRAINT ck_drivers_license_type CHECK (license_type IN ('1종보통', '1종대형', '2종보통', '2종소형', '특수')),
  CONSTRAINT ck_drivers_hazmat    CHECK (NOT hazmat_cert OR hazmat_expires_at IS NOT NULL),
  CONSTRAINT fk_drivers_org       FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_drivers_user      FOREIGN KEY (user_id)         REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_drivers_org_active ON logistics_drivers (organization_id, status);
CREATE INDEX idx_drivers_license_exp ON logistics_drivers (license_expires_at) WHERE status = 'ACTIVE';

COMMENT ON TABLE  logistics_drivers                    IS 'EL-110 운전자 마스터. user 와 1:1. rules/driver_vehicle.md.';
COMMENT ON COLUMN logistics_drivers.location_consent   IS 'EL-080 위치 로깅 동의. logistics.driver_location_logging 토글 ON 시 검증.';
COMMENT ON COLUMN logistics_drivers.license_expires_at IS 'EL-150 만료 시 ASSIGNED 차단. 30/14/7/1일 전 알림 (EL-155).';

-- ─── vehicles
CREATE TABLE logistics_vehicles (
  id                    UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       UUID            NOT NULL,
  vehicle_no            VARCHAR(20)     NOT NULL,         -- 차량번호 '12가1234'
  vehicle_type          VARCHAR(20)     NOT NULL,
  capacity_weight       NUMERIC(10, 2),                   -- kg
  capacity_volume       NUMERIC(10, 2),                   -- m3
  insurance_no          VARCHAR(50),
  insurance_expires_at  DATE,
  inspection_expires_at DATE,
  status                vehicle_status  NOT NULL DEFAULT 'ACTIVE',
  meta                  JSONB,
  created_at            TIMESTAMPTZ     NOT NULL DEFAULT now(),

  CONSTRAINT uq_vehicles_org_no    UNIQUE (organization_id, vehicle_no),
  CONSTRAINT ck_vehicles_no_format CHECK (vehicle_no ~ '^[0-9]{2,3}[가-힣][0-9]{4}$'),
  CONSTRAINT ck_vehicles_capacity  CHECK (
    (capacity_weight IS NULL OR capacity_weight > 0) AND
    (capacity_volume IS NULL OR capacity_volume > 0)
  ),
  CONSTRAINT fk_vehicles_org       FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT
);

CREATE INDEX idx_vehicles_org_active     ON logistics_vehicles (organization_id, status);
CREATE INDEX idx_vehicles_insurance_exp  ON logistics_vehicles (insurance_expires_at) WHERE status = 'ACTIVE' AND insurance_expires_at IS NOT NULL;

COMMENT ON TABLE  logistics_vehicles            IS 'EL-130 차량 마스터. KR 차량번호 형식 검증 (EL-135).';
COMMENT ON COLUMN logistics_vehicles.vehicle_no IS 'EL-135 [0-9]{2,3}[가-힣][0-9]{4} (KR 표준).';
