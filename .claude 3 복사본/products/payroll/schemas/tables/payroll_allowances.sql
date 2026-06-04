-- ════════════════════════════════════════════════════════════════════════
-- payroll_allowances — 수당 (record 자식, 항목별)
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-300 ~ EP-349 / 상세: rules/allowance.md
--
-- 핵심 원칙:
--   • record 1 : N allowances. ON DELETE CASCADE (record 갱신 시 자식 함께)
--   • 항목별 row — 명세서 / 보고서에서 분리 표시
--   • 비과세 분리 (EP-345): nontaxable_amount 식대 등
--   • record.total_allowance = SUM(allowances.amount) — 트랜잭션 안에서 정합
-- ════════════════════════════════════════════════════════════════════════

-- ─── ENUM ─────────────────────────────────────────────
CREATE TYPE allowance_type AS ENUM (
  -- 법정 가산수당 (EP-310)
  'OVERTIME',           -- 시간외 (연장) +50%
  'NIGHT',              -- 야간 +50%
  'HOLIDAY',            -- 휴일 +50% / 8h 초과 +100%
  'WEEKLY_HOLIDAY',     -- 주휴수당
  'ANNUAL_LEAVE_UNUSED',-- 연차미사용수당 (연 1회)
  -- 임의 수당 (EP-340)
  'MEAL',               -- 식대 (비과세 한도 별도 — EP-345)
  'TRANSPORT',          -- 교통비
  'POSITION',           -- 직책수당
  'HAZARD',             -- 위험수당
  'BONUS',              -- 상여
  'OTHER'
);

-- ─── 테이블 ───────────────────────────────────────────
CREATE TABLE payroll_allowances (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  -- record 자식 (EP-348)
  record_id       UUID            NOT NULL,

  -- 분류
  allowance_type  allowance_type  NOT NULL,

  -- 금액 (KRW 정수)
  amount          NUMERIC(12, 0)  NOT NULL,

  -- 과세 / 비과세 분리 (EP-345)
  -- 식대 등은 일부 비과세. 4대보험 / 소득세 산정 시 taxable_amount 만 합산
  taxable_amount  NUMERIC(12, 0)  NOT NULL,
  nontaxable_amount NUMERIC(12, 0) NOT NULL DEFAULT 0,

  -- 메타 (산출 근거 — EP-410 명세서 필수)
  -- 예: { "minutes": 120, "ordinaryHourly": 12500, "rate": 0.5 } for OVERTIME
  calculation     JSONB,
  notes           TEXT,

  -- 공통 컬럼
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  CONSTRAINT ck_allowances_amount_nonneg     CHECK (amount >= 0),
  CONSTRAINT ck_allowances_taxable_nonneg    CHECK (taxable_amount >= 0),
  CONSTRAINT ck_allowances_nontaxable_nonneg CHECK (nontaxable_amount >= 0),
  -- amount = taxable + nontaxable
  CONSTRAINT ck_allowances_amount_split      CHECK (amount = taxable_amount + nontaxable_amount),

  -- FK (CASCADE: record 삭제 시 자식 정리)
  CONSTRAINT fk_allowances_record FOREIGN KEY (record_id) REFERENCES payroll_records(id) ON DELETE CASCADE
);

-- ─── 인덱스 ───────────────────────────────────────────
CREATE INDEX idx_allowances_record       ON payroll_allowances (record_id);
CREATE INDEX idx_allowances_type         ON payroll_allowances (allowance_type);

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_allowances                IS 'EP-348 수당 항목별. record 자식. rules/allowance.md.';
COMMENT ON COLUMN payroll_allowances.taxable_amount IS 'EP-345 과세 금액 — 4대보험 / 소득세 산정 베이스.';
COMMENT ON COLUMN payroll_allowances.calculation    IS '산출 근거 JSON. 명세서 EP-410 6번 항목 (계산방법) 의 출력 소스.';

-- ════════════════════════════════════════════════════════════════════════
-- payroll_allowance_settings — 수당 설정 (정액 / 정률, 시점별)
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-340 / 상세: rules/allowance.md
-- 사용자 / 팀 / 시설 / 조직 레벨 우선순위 (EP-341): user > team > facility > org
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE payroll_allowance_settings (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope (EP-341 우선순위)
  organization_id UUID            NOT NULL,
  facility_id     UUID,
  team_id         UUID,
  user_id         UUID,                                       -- NULL = 상위 레벨 적용

  -- 분류
  allowance_type  allowance_type  NOT NULL,

  -- 금액 종류 (EP-340)
  amount_type     VARCHAR(10)     NOT NULL,                   -- 'FIXED' / 'PERCENT'
  amount          NUMERIC(12, 2)  NOT NULL,                   -- FIXED=KRW, PERCENT=% (예: 5.00 = 5%)

  -- 시점
  effective_from  DATE            NOT NULL,
  effective_to    DATE,

  notes           TEXT,
  created_by      UUID            NOT NULL,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  CONSTRAINT ck_allowance_settings_amount_type CHECK (amount_type IN ('FIXED', 'PERCENT')),
  CONSTRAINT ck_allowance_settings_amount_pos  CHECK (amount > 0),
  CONSTRAINT ck_allowance_settings_range       CHECK (effective_to IS NULL OR effective_to >= effective_from),

  -- FK
  CONSTRAINT fk_allowance_settings_org      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_allowance_settings_facility FOREIGN KEY (facility_id)     REFERENCES facilities(id)    ON DELETE RESTRICT,
  CONSTRAINT fk_allowance_settings_team     FOREIGN KEY (team_id)         REFERENCES teams(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_allowance_settings_user     FOREIGN KEY (user_id)         REFERENCES users(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_allowance_settings_creator  FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

CREATE INDEX idx_allowance_settings_user     ON payroll_allowance_settings (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_allowance_settings_team     ON payroll_allowance_settings (team_id) WHERE team_id IS NOT NULL;
CREATE INDEX idx_allowance_settings_facility ON payroll_allowance_settings (facility_id) WHERE facility_id IS NOT NULL;
CREATE INDEX idx_allowance_settings_active   ON payroll_allowance_settings (allowance_type, effective_from) WHERE effective_to IS NULL;

COMMENT ON TABLE payroll_allowance_settings IS 'EP-340 임의 수당 설정. 우선순위: user > team > facility > org (EP-341).';
