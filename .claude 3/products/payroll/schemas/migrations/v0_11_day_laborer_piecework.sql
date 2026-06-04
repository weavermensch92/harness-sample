-- ════════════════════════════════════════════════════════════════════════
-- payroll v0.11 마이그레이션 — 일용직 / piecework / feature flag 도입
-- ────────────────────────────────────────────────────────────────────────
-- 적용 순서:
--   1. 신규 ENUM 값 추가
--   2. 신규 테이블 (payroll_feature_flags, payroll_task_definitions) — 별도 파일
--   3. 기존 테이블 ALTER (이 파일)
--   4. 기존 데이터 백필 (NULL → 기본값)
--   5. 신규 CHECK / NOT NULL 제약 추가
--
-- Forward-only. Rollback 시 별도 down migration 필요.
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1. ENUM 확장 ─────────────────────────────────────

-- 1.1 work_log_source 에 PIECEWORK 추가 (EP-820)
ALTER TYPE work_log_source ADD VALUE IF NOT EXISTS 'PIECEWORK';

-- 1.2 compensation_scheme 에 PIECEWORK 추가 (EP-200 보강)
ALTER TYPE compensation_scheme ADD VALUE IF NOT EXISTS 'PIECEWORK';

-- ─── 2. payroll_compensation_settings 확장 ───────────

-- 2.1 일용직 플래그 (EP-710)
ALTER TABLE payroll_compensation_settings
  ADD COLUMN IF NOT EXISTS is_day_laborer BOOLEAN NOT NULL DEFAULT FALSE;

-- 2.2 지급 사이클 (EP-750)
ALTER TABLE payroll_compensation_settings
  ADD COLUMN IF NOT EXISTS payment_cycle VARCHAR(10) NOT NULL DEFAULT 'MONTHLY';

ALTER TABLE payroll_compensation_settings
  ADD CONSTRAINT ck_compensation_payment_cycle CHECK (
    payment_cycle IN ('DAILY', 'WEEKLY', 'MONTHLY', 'IMMEDIATE')
  );

-- 2.3 일용직 + scheme 정합 (EP-712)
ALTER TABLE payroll_compensation_settings
  ADD CONSTRAINT ck_compensation_day_laborer_scheme CHECK (
    NOT is_day_laborer OR scheme IN ('DAILY', 'HOURLY', 'PIECEWORK')
  );

-- 2.4 일용직 + payment_cycle 정합 (EP-750)
-- 일용직은 DAILY/WEEKLY/IMMEDIATE 권장. MONTHLY 도 허용하되 알림.
-- (CHECK 으로 강제하지 않음 — 정책 영역)

COMMENT ON COLUMN payroll_compensation_settings.is_day_laborer IS 'EP-710 일용근로자 플래그. TRUE 면 4대보험/세금/명세서 특례 적용. day_laborer.md 참조.';
COMMENT ON COLUMN payroll_compensation_settings.payment_cycle  IS 'EP-750 지급 사이클. DAILY/WEEKLY/MONTHLY/IMMEDIATE.';

-- ─── 3. payroll_records 확장 ─────────────────────────

-- 3.1 period_type — 일/주/월/단가 단위 (EP-260 보강)
ALTER TABLE payroll_records
  ADD COLUMN IF NOT EXISTS period_type VARCHAR(10) NOT NULL DEFAULT 'MONTHLY';

ALTER TABLE payroll_records
  ADD CONSTRAINT ck_records_period_type CHECK (
    period_type IN ('MONTHLY', 'WEEKLY', 'DAILY', 'PIECE')
  );

-- 3.2 period_key — 통일 키 (월='YYYY-MM', 일='YYYY-MM-DD', 주='YYYY-Www')
-- 기존 month 컬럼 유지하되 period_key 추가 (호환성)
ALTER TABLE payroll_records
  ADD COLUMN IF NOT EXISTS period_key VARCHAR(20);

-- 백필: 기존 row 의 period_key = month
UPDATE payroll_records
SET period_key = month
WHERE period_key IS NULL;

-- 백필 후 NOT NULL 강제
ALTER TABLE payroll_records
  ALTER COLUMN period_key SET NOT NULL;

-- UNIQUE 갱신 (기존 user_id, month, version → user_id, period_type, period_key, version)
-- 기존 인덱스는 일단 유지 (Phase 1+ 에서 정리)
ALTER TABLE payroll_records
  ADD CONSTRAINT uq_records_user_period_version UNIQUE (user_id, period_type, period_key, version);

-- 3.3 일용직 record 식별 (EP-861)
ALTER TABLE payroll_records
  ADD COLUMN IF NOT EXISTS is_day_laborer_record BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN payroll_records.period_type           IS 'EP-260 보강. 일용직/piecework 도입으로 일/주/월 다양화.';
COMMENT ON COLUMN payroll_records.period_key            IS 'period_type 별 키. MONTHLY=YYYY-MM / WEEKLY=YYYY-Www / DAILY=YYYY-MM-DD / PIECE=task_code:date.';
COMMENT ON COLUMN payroll_records.is_day_laborer_record IS 'EP-725 일용직 record. 종합과세 / 연말정산 제외 표시.';

-- ─── 4. payroll_payments 확장 ───────────────────────

-- 4.1 지급 사이클 기록 (EP-750)
ALTER TABLE payroll_payments
  ADD COLUMN IF NOT EXISTS payment_cycle VARCHAR(10) NOT NULL DEFAULT 'MONTHLY';

ALTER TABLE payroll_payments
  ADD CONSTRAINT ck_payments_payment_cycle CHECK (
    payment_cycle IN ('DAILY', 'WEEKLY', 'MONTHLY', 'IMMEDIATE')
  );

COMMENT ON COLUMN payroll_payments.payment_cycle IS 'EP-750 지급 사이클 스냅샷 (compensation_settings 변경에 영향 안 받음).';

-- ─── 5. work_logs 확장 ──────────────────────────────

-- 5.1 PIECEWORK 정합 (이미 ENUM 추가했으니 UNIQUE 그대로 유효)
-- piecework 메타 (선택): JSONB 추가
ALTER TABLE work_logs
  ADD COLUMN IF NOT EXISTS piecework_meta JSONB;

-- piecework_meta 예시:
-- { "task_code": "DELIVERY_3KM", "quantity": 12, "unit_price": 5000, "external_ref": "order_98765" }

COMMENT ON COLUMN work_logs.piecework_meta IS 'EP-825 PIECEWORK source 인 경우 산출 근거 보존. task_code/quantity/unit_price.';

-- ─── 6. deduction_rates 신규 entry (참고용 INSERT) ──

-- 일용직 소득세 (EP-721) — 운영 시 매년 갱신
-- INSERT INTO deduction_rates (deduction_type, effective_year, rate_employee, ceiling, notes)
-- VALUES
--   ('INCOME_TAX_DAY_LABORER', 2026, 0.06000, NULL, '일용직 소득세율 6% (소득세법 §129)')
-- ON CONFLICT DO NOTHING;

-- 비과세 일급 / 공제율은 별도 settings 테이블 또는 organization 설정으로 운영
-- (deduction_rates 는 단순 요율, 한도 / 공제 는 별도)

-- ─── 7. 검증 쿼리 (마이그레이션 후 수동 실행 권장) ──

-- 7.1 기존 데이터 정합 확인
-- SELECT count(*) FROM payroll_records WHERE period_key IS NULL;  -- 0 이어야 함
-- SELECT count(*) FROM payroll_records WHERE period_type IS NULL; -- 0 이어야 함

-- 7.2 신규 ENUM 값 사용 가능 확인
-- SELECT 'PIECEWORK'::work_log_source;        -- 에러 없어야 함
-- SELECT 'PIECEWORK'::compensation_scheme;    -- 에러 없어야 함

-- ════════════════════════════════════════════════════════════════════════
-- 마이그레이션 완료. 다음 단계:
--   • 운영자 (L4 / Super) 가 payroll_feature_flags 에서 day_laborer / piecework 토글
--   • 토글 ON 후 task_definitions 등록 (piecework) / 일용직 사용자 is_day_laborer 설정
-- ════════════════════════════════════════════════════════════════════════
