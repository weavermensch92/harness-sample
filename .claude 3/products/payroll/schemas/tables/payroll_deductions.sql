-- ════════════════════════════════════════════════════════════════════════
-- payroll_deductions — 공제 (record 자식, 항목별)
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-350 ~ EP-399 / 상세: rules/deduction.md
--
-- 핵심 원칙:
--   • record 1 : N deductions. ON DELETE CASCADE
--   • 합계 정합 (EP-391): record.total_deduction = SUM(deductions.amount)
--   • 음수 금지 (EP-395) — 환급은 allowance 의 음수 또는 별도 트랜잭션
--   • 요율 / 베이스 보존 (EP-396) — 사후 분쟁 시 추적 가능
--   • 산재보험은 100% 사업주 부담 → deduction 대상 아님
-- ════════════════════════════════════════════════════════════════════════

-- ─── ENUM ─────────────────────────────────────────────
CREATE TYPE deduction_type AS ENUM (
  -- 법정 (4대보험)
  'NATIONAL_PENSION',     -- 국민연금
  'HEALTH_INSURANCE',     -- 건강보험
  'LONG_TERM_CARE',       -- 장기요양보험 (건강보험 부속)
  'EMPLOYMENT_INSURANCE', -- 고용보험
  -- 법정 (세금)
  'INCOME_TAX',           -- 소득세 (간이세액)
  'LOCAL_INCOME_TAX',     -- 지방소득세 (소득세의 10%)
  -- 임의
  'COMPANY_LOAN',         -- 사내 대출 상환
  'UNION_FEE',            -- 노조비
  'OTHER'
);

-- ─── 테이블 ───────────────────────────────────────────
CREATE TABLE payroll_deductions (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  -- record 자식 (EP-390)
  record_id       UUID            NOT NULL,

  -- 분류
  deduction_type  deduction_type  NOT NULL,

  -- 금액 (KRW 정수)
  amount          NUMERIC(12, 0)  NOT NULL,

  -- 산정 근거 (EP-396 사후 추적)
  rate_used       NUMERIC(7, 5),                  -- 적용된 요율 (e.g. 0.04500 = 4.5%)
  base_used       NUMERIC(12, 0),                 -- 적용 기준액 (보수월액 등)

  -- 메타 (산출 근거 — EP-410 명세서 6번 항목)
  -- 예: { "year": 2026, "ceiling": 5900000, "actualBase": 4500000 } for NATIONAL_PENSION
  -- 예: { "dependents": 2, "option": 1.0, "table": "simple_2026" } for INCOME_TAX
  calculation     JSONB,
  notes           TEXT,

  -- 공통 컬럼
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- 음수 금지 (EP-395)
  CONSTRAINT ck_deductions_amount_nonneg CHECK (amount >= 0),
  -- rate_used 가 있으면 0~1 사이
  CONSTRAINT ck_deductions_rate_range    CHECK (
    rate_used IS NULL OR (rate_used >= 0 AND rate_used <= 1)
  ),
  -- base_used 음수 금지
  CONSTRAINT ck_deductions_base_nonneg   CHECK (base_used IS NULL OR base_used >= 0),

  -- FK (CASCADE: record 삭제 시 자식 정리)
  CONSTRAINT fk_deductions_record FOREIGN KEY (record_id) REFERENCES payroll_records(id) ON DELETE CASCADE
);

-- ─── 인덱스 ───────────────────────────────────────────
CREATE INDEX idx_deductions_record       ON payroll_deductions (record_id);
CREATE INDEX idx_deductions_type         ON payroll_deductions (deduction_type);

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_deductions             IS 'EP-390 공제 항목별. record 자식. 합계 정합 EP-391. rules/deduction.md.';
COMMENT ON COLUMN payroll_deductions.rate_used   IS 'EP-396 적용된 요율 보존. deduction_rates 변경 후에도 과거 record 검증 가능.';
COMMENT ON COLUMN payroll_deductions.base_used   IS 'EP-396 적용 기준액 (보수월액 등). 사후 분쟁 시 추적.';
COMMENT ON COLUMN payroll_deductions.calculation IS '산출 근거 JSON. 명세서 EP-410 6번 항목 (계산방법) 의 출력 소스.';

-- ════════════════════════════════════════════════════════════════════════
-- payroll_deduction_settings — 임의 공제 설정 (사용자별)
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-388 / 상세: rules/deduction.md
-- 사내 대출 / 노조비 / 기타. 4대보험 / 세금은 deduction_rates 별도.
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE payroll_deduction_settings (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  organization_id UUID            NOT NULL,
  user_id         UUID            NOT NULL,

  deduction_type  deduction_type  NOT NULL,         -- 임의 타입만 권장

  amount_type     VARCHAR(10)     NOT NULL,          -- 'FIXED' / 'PERCENT'
  amount          NUMERIC(12, 2)  NOT NULL,

  schedule        VARCHAR(20)     NOT NULL,          -- 'MONTHLY' / 'ONCE'
  remaining       NUMERIC(12, 0),                    -- 대출 잔액 (0 도달 시 자동 종료)

  -- 동의 문서 (EP-389 KR §43 임의 공제 근거)
  consent_doc_url VARCHAR(500),

  effective_from  DATE            NOT NULL,
  effective_to    DATE,

  notes           TEXT,
  created_by      UUID            NOT NULL,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  CONSTRAINT ck_deduction_settings_amount_type CHECK (amount_type IN ('FIXED', 'PERCENT')),
  CONSTRAINT ck_deduction_settings_schedule    CHECK (schedule IN ('MONTHLY', 'ONCE')),
  CONSTRAINT ck_deduction_settings_amount_pos  CHECK (amount > 0),
  CONSTRAINT ck_deduction_settings_remaining   CHECK (remaining IS NULL OR remaining >= 0),
  CONSTRAINT ck_deduction_settings_range       CHECK (effective_to IS NULL OR effective_to >= effective_from),

  -- FK
  CONSTRAINT fk_deduction_settings_org     FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_deduction_settings_user    FOREIGN KEY (user_id)         REFERENCES users(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_deduction_settings_creator FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

CREATE INDEX idx_deduction_settings_user    ON payroll_deduction_settings (user_id);
CREATE INDEX idx_deduction_settings_active  ON payroll_deduction_settings (user_id, deduction_type) WHERE effective_to IS NULL;

COMMENT ON TABLE  payroll_deduction_settings IS 'EP-388 임의 공제 설정 (사내대출/노조비). 4대보험 요율은 deduction_rates 별도.';
COMMENT ON COLUMN payroll_deduction_settings.consent_doc_url IS 'EP-389 KR §43 임의 공제 동의 문서. 권고 필드.';
