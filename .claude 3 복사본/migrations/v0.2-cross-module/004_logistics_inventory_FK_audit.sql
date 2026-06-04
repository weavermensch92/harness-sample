-- ════════════════════════════════════════════════════════════════════════
-- Migration 004 (v0.2) — Cross-module FK 검증 (실 변경 X, 진단만)
-- Module: logistics (영향: inventory)
-- 목적: logistics → inventory FK 정합 검증 + 누락 시 추가
-- ════════════════════════════════════════════════════════════════════════
--
-- 배경:
-- - logistics_deliveries.warehouse_id → inventory_warehouses(id)
-- - logistics_delivery_lines.item_id → inventory_items(id)
-- - logistics_delivery_lines.lot_id → inventory_lots(id)  (옵션)
-- - logistics_delivery_lines.serial_id → inventory_serials(id)  (옵션)
-- - logistics_routes.warehouse_id → inventory_warehouses(id)
-- - logistics_return_requests.target_warehouse_id → inventory_warehouses(id)
--
-- 모듈 마이그레이션 순서 (Prisma 가 자동 처리하지만 SQL 직접 적용 시 명시):
-- 1. organizations / users / facilities (글로벌 마스터)
-- 2. inventory (warehouses → items → lots / serials → 기타)
-- 3. payroll (organizations + users 의존만)
-- 4. logistics (organizations + users + inventory 의존)
-- 5. reports (organizations + users 의존, 다른 모듈 데이터는 application 레벨)
--
-- ════════════════════════════════════════════════════════════════════════

-- ─── FK 존재 여부 검증 (진단 쿼리 — 실행 후 결과 확인) ─────────────────
DO $$
DECLARE
  fk_count INTEGER;
BEGIN
  -- logistics_deliveries.warehouse_id → inventory_warehouses
  SELECT COUNT(*) INTO fk_count
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
   WHERE tc.constraint_type = 'FOREIGN KEY'
     AND tc.table_name = 'logistics_deliveries'
     AND ccu.table_name = 'inventory_warehouses';
  IF fk_count = 0 THEN
    RAISE NOTICE '[MISSING] logistics_deliveries.warehouse_id → inventory_warehouses';
  ELSE
    RAISE NOTICE '[OK] logistics_deliveries.warehouse_id FK 존재';
  END IF;

  -- logistics_delivery_lines.item_id → inventory_items
  SELECT COUNT(*) INTO fk_count
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
   WHERE tc.constraint_type = 'FOREIGN KEY'
     AND tc.table_name = 'logistics_delivery_lines'
     AND ccu.table_name = 'inventory_items';
  IF fk_count = 0 THEN
    RAISE NOTICE '[MISSING] logistics_delivery_lines.item_id → inventory_items';
  ELSE
    RAISE NOTICE '[OK] logistics_delivery_lines.item_id FK 존재';
  END IF;

  -- logistics_routes.warehouse_id → inventory_warehouses
  SELECT COUNT(*) INTO fk_count
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
   WHERE tc.constraint_type = 'FOREIGN KEY'
     AND tc.table_name = 'logistics_routes'
     AND ccu.table_name = 'inventory_warehouses';
  IF fk_count = 0 THEN
    RAISE NOTICE '[MISSING] logistics_routes.warehouse_id → inventory_warehouses';
  ELSE
    RAISE NOTICE '[OK] logistics_routes.warehouse_id FK 존재';
  END IF;

  -- logistics_return_requests.target_warehouse_id → inventory_warehouses
  SELECT COUNT(*) INTO fk_count
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
   WHERE tc.constraint_type = 'FOREIGN KEY'
     AND tc.table_name = 'logistics_return_requests'
     AND ccu.table_name = 'inventory_warehouses';
  IF fk_count = 0 THEN
    RAISE NOTICE '[MISSING] logistics_return_requests.target_warehouse_id → inventory_warehouses';
  ELSE
    RAISE NOTICE '[OK] logistics_return_requests.target_warehouse_id FK 존재';
  END IF;
END $$;

-- ─── 누락 시 수동 추가 (필요한 경우만 — 위 진단에서 MISSING 으로 나온 것만) ──
-- ALTER TABLE logistics_deliveries
--   ADD CONSTRAINT fk_deliveries_warehouse
--     FOREIGN KEY (warehouse_id) REFERENCES inventory_warehouses(id) ON DELETE RESTRICT;
--
-- ALTER TABLE logistics_delivery_lines
--   ADD CONSTRAINT fk_delivery_lines_item
--     FOREIGN KEY (item_id) REFERENCES inventory_items(id) ON DELETE RESTRICT;
--
-- ALTER TABLE logistics_delivery_lines
--   ADD CONSTRAINT fk_delivery_lines_lot
--     FOREIGN KEY (lot_id) REFERENCES inventory_lots(id) ON DELETE RESTRICT;
--
-- ALTER TABLE logistics_routes
--   ADD CONSTRAINT fk_routes_warehouse
--     FOREIGN KEY (warehouse_id) REFERENCES inventory_warehouses(id) ON DELETE RESTRICT;
--
-- ALTER TABLE logistics_return_requests
--   ADD CONSTRAINT fk_returns_warehouse
--     FOREIGN KEY (target_warehouse_id) REFERENCES inventory_warehouses(id) ON DELETE RESTRICT;

-- ════════════════════════════════════════════════════════════════════════
-- Prisma 가 정식 마이그레이션 소스 (database.md § 7.1)
-- 위 SQL 은 진단 + emergency 수동 적용 가이드
-- 실 마이그레이션은 Prisma schema 변경으로 처리
-- ════════════════════════════════════════════════════════════════════════
