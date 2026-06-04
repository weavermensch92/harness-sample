-- ════════════════════════════════════════════════════════════════════════
-- Migration 002 (v0.2) — Cross-module
-- Module: inventory (영향: logistics)
-- 목적: inventory_items 에 물리 속성 (무게 / 부피) 컬럼 추가
-- 룰: EI-024 (item_master 신규) / EL-160 (logistics 적재 검증) / EL-420 (운임 산정)
-- ════════════════════════════════════════════════════════════════════════
--
-- 배경:
-- - logistics 의 driver_vehicle.md (EL-160) — 적재 검증 시 item.weight / volume 필요
-- - logistics 의 shipping_cost.md (EL-420) — 운임 산정 시 무게 / 부피 기반 단가
-- - 현재 inventory_items 에 weight / volume 컬럼 없음 — 검증 skip + 운임 단가 부정확
--
-- 단위 표준 (database.md § 3.2):
-- - 무게 NUMERIC(10, 2) kg, 부피 NUMERIC(10, 2) m³
-- - 단위가 다른 케이스 (g, ml 등) 는 weight_uom / volume_uom 컬럼으로 표시
-- - 적재 / 운임 계산 시 application 측에서 base 단위로 변환
--
-- 적용 순서: DB → application deploy
-- 롤백: 컬럼 DROP 가능 (데이터 손실 발생 — 백업 필수)
-- 안전: NULL 허용 (기존 row 영향 X). 향후 정책에 따라 NOT NULL 강제 가능.
-- ════════════════════════════════════════════════════════════════════════

ALTER TABLE inventory_items
  ADD COLUMN IF NOT EXISTS weight        NUMERIC(10, 2),       -- 단위는 weight_uom
  ADD COLUMN IF NOT EXISTS weight_uom    VARCHAR(10),          -- 'kg' (기본) / 'g' / 'lb' / 'oz'
  ADD COLUMN IF NOT EXISTS volume        NUMERIC(10, 2),       -- 단위는 volume_uom
  ADD COLUMN IF NOT EXISTS volume_uom    VARCHAR(10),          -- 'm3' (기본) / 'l' / 'ml' / 'cm3'
  ADD COLUMN IF NOT EXISTS dim_length_cm NUMERIC(10, 2),       -- 가로 (운송 적재 모델링)
  ADD COLUMN IF NOT EXISTS dim_width_cm  NUMERIC(10, 2),       -- 세로
  ADD COLUMN IF NOT EXISTS dim_height_cm NUMERIC(10, 2);       -- 높이

-- ─── 제약 ─────────────────────────────────────────────────────────────
-- 무게 / 부피 양수 (NULL 허용)
ALTER TABLE inventory_items
  ADD CONSTRAINT ck_items_weight_positive
    CHECK (weight IS NULL OR weight > 0),
  ADD CONSTRAINT ck_items_volume_positive
    CHECK (volume IS NULL OR volume > 0),
  ADD CONSTRAINT ck_items_dim_length CHECK (dim_length_cm IS NULL OR dim_length_cm > 0),
  ADD CONSTRAINT ck_items_dim_width  CHECK (dim_width_cm  IS NULL OR dim_width_cm  > 0),
  ADD CONSTRAINT ck_items_dim_height CHECK (dim_height_cm IS NULL OR dim_height_cm > 0);

-- ─── 표준 단위 (제약 — 화이트리스트) ──────────────────────────────────
ALTER TABLE inventory_items
  ADD CONSTRAINT ck_items_weight_uom
    CHECK (weight_uom IS NULL OR weight_uom IN ('kg', 'g', 'lb', 'oz', 't')),
  ADD CONSTRAINT ck_items_volume_uom
    CHECK (volume_uom IS NULL OR volume_uom IN ('m3', 'l', 'ml', 'cm3'));

-- ─── 무게 / 부피 정합: 둘 다 있거나 둘 다 NULL ────────────────────────
ALTER TABLE inventory_items
  ADD CONSTRAINT ck_items_weight_pair
    CHECK ((weight IS NULL) = (weight_uom IS NULL)),
  ADD CONSTRAINT ck_items_volume_pair
    CHECK ((volume IS NULL) = (volume_uom IS NULL));

-- ─── 코멘트 (PII 컬럼은 X, 단순 도메인 메타) ───────────────────────────
COMMENT ON COLUMN inventory_items.weight        IS 'EI-024 단일 단위 무게. 단위는 weight_uom. logistics EL-160 적재 검증.';
COMMENT ON COLUMN inventory_items.weight_uom    IS '무게 단위: kg / g / lb / oz / t. 기본 kg.';
COMMENT ON COLUMN inventory_items.volume        IS 'EI-024 단일 단위 부피. 단위는 volume_uom. logistics EL-420 운임 산정.';
COMMENT ON COLUMN inventory_items.volume_uom    IS '부피 단위: m3 / l / ml / cm3. 기본 m3.';
COMMENT ON COLUMN inventory_items.dim_length_cm IS '가로 (cm). 운송 적재 모델링 (Phase 1+).';
COMMENT ON COLUMN inventory_items.dim_width_cm  IS '세로 (cm).';
COMMENT ON COLUMN inventory_items.dim_height_cm IS '높이 (cm).';

-- ════════════════════════════════════════════════════════════════════════
-- 영향 받는 룰 / 코드 (Phase 1 구현 시):
-- 1. inventory/rules/item_master.md:
--    - EI-024 신규 룰: 물리 속성 (무게 / 부피 / 차원)
--    - 단위 표준 + 변환 (UOM)
-- 2. logistics/rules/driver_vehicle.md:
--    - EL-160 적재 검증 — item.weight / volume 데이터 있을 때 강제 검증
-- 3. logistics/rules/shipping_cost.md:
--    - EL-420 운임 산정 — totalWeight / totalVolume 계산 (NULL 처리 명시)
-- 4. business/logistics/services/capacity-validator.ts (Phase 1+)
-- 5. business/logistics/services/shipping-cost-service.ts (Phase 1+)
--
-- 데이터 백필 (옵션, 운영 시점):
-- 기존 품목의 무게 / 부피 데이터를 외부 시스템에서 import 또는 운영자가 수동 입력.
-- 백필 전까지 NULL → 적재 검증 skip + 경고 (driver_vehicle.md EL-160 참조).
-- ════════════════════════════════════════════════════════════════════════
