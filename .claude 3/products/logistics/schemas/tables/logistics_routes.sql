-- ════════════════════════════════════════════════════════════════════════
-- logistics_routes + logistics_route_stops
-- 룰 EL-200 ~ EL-299 / 상세: rules/route.md
-- 게이트: logistics.route_optimization (자동 최적화 시)
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE route_status      AS ENUM ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED');
CREATE TYPE route_stop_status AS ENUM ('PENDING', 'VISITED', 'SKIPPED');

CREATE TABLE logistics_routes (
  id                    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       UUID         NOT NULL,
  warehouse_id          UUID         NOT NULL,
  driver_id             UUID,
  vehicle_id            UUID,
  scheduled_date        DATE         NOT NULL,
  scheduled_start_at    TIMESTAMPTZ,
  status                route_status NOT NULL DEFAULT 'PLANNED',
  total_distance_km     NUMERIC(10, 3),
  total_stops           SMALLINT     NOT NULL DEFAULT 0,
  optimization_method   VARCHAR(20),                    -- 'manual' / 'auto_google' / 'auto_tmap'
  optimized_at          TIMESTAMPTZ,
  started_at            TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,
  notes                 TEXT,
  created_by            UUID         NOT NULL,
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),

  CONSTRAINT ck_routes_total_stops    CHECK (total_stops >= 0),
  CONSTRAINT ck_routes_distance       CHECK (total_distance_km IS NULL OR total_distance_km >= 0),
  CONSTRAINT fk_routes_organization   FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_routes_warehouse      FOREIGN KEY (warehouse_id)    REFERENCES inventory_warehouses(id) ON DELETE RESTRICT,
  CONSTRAINT fk_routes_driver         FOREIGN KEY (driver_id)       REFERENCES logistics_drivers(id) ON DELETE RESTRICT,
  CONSTRAINT fk_routes_vehicle        FOREIGN KEY (vehicle_id)      REFERENCES logistics_vehicles(id) ON DELETE RESTRICT,
  CONSTRAINT fk_routes_creator        FOREIGN KEY (created_by)      REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_routes_org_status     ON logistics_routes (organization_id, status);
CREATE INDEX idx_routes_driver_date    ON logistics_routes (driver_id, scheduled_date) WHERE driver_id IS NOT NULL;
CREATE INDEX idx_routes_active         ON logistics_routes (organization_id, scheduled_date) WHERE status = 'IN_PROGRESS';

COMMENT ON TABLE  logistics_routes IS 'EL-210 묶음 배송. 1 기사 1 차량 1 회 운행. PLANNED→IN_PROGRESS→COMPLETED/CANCELLED.';

-- ─── route_stops
CREATE TABLE logistics_route_stops (
  id                       UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id                 UUID              NOT NULL,
  delivery_id              UUID              NOT NULL,
  sequence_no              SMALLINT          NOT NULL,
  estimated_arrival_at     TIMESTAMPTZ,
  actual_arrival_at        TIMESTAMPTZ,
  actual_departure_at      TIMESTAMPTZ,
  distance_from_prev_km    NUMERIC(10, 3),
  status                   route_stop_status NOT NULL DEFAULT 'PENDING',

  CONSTRAINT uq_route_stops_seq         UNIQUE (route_id, sequence_no),
  CONSTRAINT uq_route_stops_delivery    UNIQUE (route_id, delivery_id),
  CONSTRAINT ck_route_stops_seq         CHECK (sequence_no > 0),
  CONSTRAINT fk_route_stops_route       FOREIGN KEY (route_id)    REFERENCES logistics_routes(id) ON DELETE CASCADE,
  CONSTRAINT fk_route_stops_delivery    FOREIGN KEY (delivery_id) REFERENCES logistics_deliveries(id) ON DELETE RESTRICT
);

CREATE INDEX idx_route_stops_pending ON logistics_route_stops (route_id) WHERE status = 'PENDING';
COMMENT ON TABLE logistics_route_stops IS 'EL-210 route 의 방문 stop. (route_id, sequence_no) UNIQUE 로 순서 관리.';
