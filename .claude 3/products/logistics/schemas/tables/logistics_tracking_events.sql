-- ════════════════════════════════════════════════════════════════════════
-- logistics_tracking_events + logistics_pods
-- 룰 EL-300 ~ EL-399 / 상세: rules/tracking_pod.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE logistics_tracking_events (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id     UUID            NOT NULL,
  event_type      VARCHAR(30)     NOT NULL,
  -- DISPATCHED / IN_TRANSIT_LOCATION / ARRIVED_AT_STOP / DELIVERY_ATTEMPT / DELIVERED / FAILED / RETURNED / CARRIER_UPDATE
  event_at        TIMESTAMPTZ     NOT NULL,
  source          VARCHAR(30)     NOT NULL,       -- driver_app / carrier_cj / carrier_hanjin / system
  source_id       VARCHAR(100),                    -- 외부 ID (멱등 키)
  -- 위치 (PII, 5자리 ~1m 또는 7자리)
  lat             NUMERIC(10, 7),
  lng             NUMERIC(10, 7),
  payload         JSONB,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- 멱등 (EL-318)
  CONSTRAINT uq_tracking_events UNIQUE NULLS NOT DISTINCT (delivery_id, source, source_id),
  CONSTRAINT ck_tracking_events_lat CHECK (lat IS NULL OR (lat >= -90 AND lat <= 90)),
  CONSTRAINT ck_tracking_events_lng CHECK (lng IS NULL OR (lng >= -180 AND lng <= 180)),
  CONSTRAINT fk_tracking_events_delivery FOREIGN KEY (delivery_id) REFERENCES logistics_deliveries(id) ON DELETE CASCADE
);

CREATE INDEX idx_tracking_events_delivery ON logistics_tracking_events (delivery_id, event_at DESC);
CREATE INDEX idx_tracking_events_carrier  ON logistics_tracking_events (source) WHERE source LIKE 'carrier_%';

COMMENT ON TABLE  logistics_tracking_events            IS 'EL-310 추적 이벤트 append-only. 멱등 (delivery, source, source_id) UNIQUE.';
COMMENT ON COLUMN logistics_tracking_events.lat        IS 'PII (EL-350). 7자리 정밀도 = 1cm. 운영상 5자리 (1m) 권장.';
COMMENT ON COLUMN logistics_tracking_events.source_id  IS 'EL-318 carrier event_id 등. 같은 ID 중복 INSERT 시 UNIQUE 위반 (멱등).';

-- ─── PODs
CREATE TYPE pod_recipient_kind AS ENUM ('SELF', 'DELEGATE', 'DOORSTEP', 'SECURITY');

CREATE TABLE logistics_pods (
  id                  UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id         UUID               NOT NULL,
  recipient_kind      pod_recipient_kind NOT NULL,
  delegate_name       VARCHAR(100),                    -- 위임 수령인 이름 (PII)
  delegate_relation   VARCHAR(50),
  signature_url       TEXT,                            -- 서명 이미지 (signed URL, TTL)
  photo_urls          TEXT[],                          -- 사진 URLs
  id_verified         BOOLEAN            NOT NULL DEFAULT FALSE,
  id_method           VARCHAR(30),                    -- mobile_oauth / driver_license_photo / manual
  id_meta             JSONB,                           -- 검증 결과 (해시 / 마스킹 ID)
  completed_at        TIMESTAMPTZ        NOT NULL,
  lat                 NUMERIC(10, 7),
  lng                 NUMERIC(10, 7),
  notes               TEXT,
  created_by          UUID               NOT NULL,    -- driver
  created_at          TIMESTAMPTZ        NOT NULL DEFAULT now(),

  -- 1 delivery = 1 POD (Phase 0)
  CONSTRAINT uq_pods_delivery UNIQUE (delivery_id),
  CONSTRAINT ck_pods_delegate CHECK (
    (recipient_kind = 'DELEGATE' AND delegate_name IS NOT NULL) OR
    (recipient_kind <> 'DELEGATE')
  ),
  CONSTRAINT ck_pods_id_method CHECK (
    NOT id_verified OR id_method IS NOT NULL
  ),
  CONSTRAINT fk_pods_delivery FOREIGN KEY (delivery_id) REFERENCES logistics_deliveries(id) ON DELETE RESTRICT,
  CONSTRAINT fk_pods_creator  FOREIGN KEY (created_by)  REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_pods_completed_at ON logistics_pods (completed_at);

COMMENT ON TABLE  logistics_pods              IS 'EL-320 수령확인. delivery 1:1. POD 등록이 DELIVERED 전이 트리거 (EL-330).';
COMMENT ON COLUMN logistics_pods.signature_url IS 'PII (EL-355). signed URL + TTL 15분. 외부 storage (S3/GCS).';
COMMENT ON COLUMN logistics_pods.id_meta       IS 'EL-348 신분증 정보. 주민번호 뒷자리는 SHA-256 해시만 저장.';
