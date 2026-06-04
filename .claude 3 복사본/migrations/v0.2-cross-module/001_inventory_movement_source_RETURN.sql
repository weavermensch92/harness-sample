-- ════════════════════════════════════════════════════════════════════════
-- Migration 001 (v0.2) — Cross-module
-- Module: inventory (영향: logistics)
-- 목적: movement_source ENUM 에 'RETURN' 값 추가 (logistics returns 정합)
-- 룰: EI-100 (stock_movement) / EL-550 (returns)
-- ════════════════════════════════════════════════════════════════════════
--
-- 배경:
-- - logistics 모듈의 returns.md (EL-550) — RETURN 처리 시 inventory IN movement
--   생성 시 source_type='RETURN' 사용
-- - 현재 inventory_movements.source_type ENUM (movement_source) 에 RETURN 값 없음
-- - 따라서 logistics returns 핸들러가 동작 X — ENUM 위반
--
-- 적용 순서: DB 마이그레이션 → application deploy (구버전 호환 유지)
-- 롤백: 신규 RETURN movement 가 INSERT 된 후에는 ENUM 값 제거 불가 (PG 제약).
--       데이터 보존 + 별도 마이그레이션으로 별도 컬럼 분리 시에만 가능.
-- ════════════════════════════════════════════════════════════════════════

-- PostgreSQL: ENUM 값 추가는 트랜잭션 외부에서 실행 필수
-- (PG 12+ ADD VALUE 자체는 트랜잭션 안에서 가능하나, 같은 트랜잭션 내 사용은 X)

ALTER TYPE movement_source ADD VALUE IF NOT EXISTS 'RETURN' AFTER 'EXPIRY_DISPOSAL';

-- 검증 쿼리 (마이그레이션 후 실행)
-- SELECT enum_range(NULL::movement_source);
-- 기대 결과: {PURCHASE, ORDER, DELIVERY, MANUAL, COUNT_ADJUSTMENT, REVERSAL, TRANSFER_INTERNAL, EXPIRY_DISPOSAL, RETURN}

-- ════════════════════════════════════════════════════════════════════════
-- 영향 받는 룰 / 코드 (Phase 1 구현 시):
-- 1. inventory/rules/stock_movement.md:
--    - EI-110 source_type 표에 RETURN 추가
--    - source_id 형식: 'rtn:{return_request_id}:{return_line_id}'
-- 2. logistics/rules/returns.md:
--    - EL-550 IN movement 생성 시 sourceType: 'RETURN' 사용
-- 3. business/logistics/handlers/return-received-handler.ts (Phase 1+ 구현)
-- ════════════════════════════════════════════════════════════════════════
