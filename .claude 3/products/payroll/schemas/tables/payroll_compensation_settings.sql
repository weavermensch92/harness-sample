-- ════════════════════════════════════════════════════════════════════════
-- payroll_compensation_settings — 사용자별 보수 설정
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-200 ~ EP-219 / 상세: rules/salary_calc.md
--
-- 핵심 원칙:
--   • 4가지 체계: MONTHLY / DAILY / HOURLY / ANNUAL
--   • 시점 조회 (EP-201) — effective_from / effective_to 로 history
--   • 변경은 항상 새 row INSERT (EP-205) — UPDATE 금지
--   • 최저임금 검증 (EP-240) — INSERT 트리거 또는 애플리케이션 레벨
-- ════════════════════════════════════════════════════════════════════════

-- ─── ENUM ─────────────────────────────────────────────
CREATE TYPE compensation_scheme AS ENUM (
  'MONTHLY',   -- 월급제
  'DAILY',     -- 일급제
  'HOURLY',    -- 시급제
  'ANNUAL',    -- 연봉제
  'PIECEWORK'  -- 단가제 (EP-200 보강, piecework.md / 게이트: payroll.piecework)
);

-- ─── 테이블 ───────────────────────────────────────────
CREATE TABLE payroll_compensation_settings (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope
  organization_id UUID                NOT NULL,
  user_id         UUID                NOT NULL,

  -- 보수 체계 (EP-200)
  scheme          compensation_scheme NOT NULL,
  base_amount     NUMERIC(12, 0)      NOT NULL,           -- KRW 정수
                                                           --   MONTHLY: 월 지급액
                                                           --   DAILY:   1일 지급액
                                                           --   HOURLY:  1시간 지급액
                                                           --   ANNUAL:  연간 총액

  -- 시점 (EP-201)
  effective_from  DATE                NOT NULL,
  effective_to    DATE,                                    -- NULL = 현재 유효

  -- 단시간 / 일용 플래그 (EP-375)
  -- TRUE 면 4대보험 가입 제외 대상 — 공제 산정에서 skip
  is_short_time   BOOLEAN             NOT NULL DEFAULT FALSE,

  -- 부양가족 수 (EP-381 소득세 간이세액 산정용)
  dependents      INTEGER             NOT NULL DEFAULT 1,

  -- 간이세액 옵션 (EP-382: 80% / 100% / 120%)
  -- 0.80 / 1.00 / 1.20 중 하나
  simple_rate_option NUMERIC(3, 2)    NOT NULL DEFAULT 1.00,

  -- ─── 일용직 / 지급사이클 (v0.11 추가) ───────────────
  -- 일용근로자 플래그 (EP-710, day_laborer.md)
  -- TRUE 면 4대보험 / 세금 / 명세서 특례 적용
  -- 게이트: payroll.day_laborer 토글 ON 인 경우만 의미 있음
  is_day_laborer  BOOLEAN             NOT NULL DEFAULT FALSE,

  -- 지급 사이클 (EP-750)
  -- DAILY    : 당일 즉시 지급 (일용직 + DAILY 자주)
  -- WEEKLY   : 주 1회
  -- MONTHLY  : 월 1회 (정규직 기본)
  -- IMMEDIATE: 작업 완료 즉시 (배송 / 도급)
  payment_cycle   VARCHAR(10)         NOT NULL DEFAULT 'MONTHLY',

  notes           TEXT,
  created_by      UUID                NOT NULL,
  created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- 같은 사용자에 동일 effective_from 두 row 금지 (변경 이력 무결성)
  CONSTRAINT uq_compensation_user_from UNIQUE (user_id, effective_from),

  -- effective_to 는 from 이후
  CONSTRAINT ck_compensation_effective_range CHECK (
    effective_to IS NULL OR effective_to >= effective_from
  ),

  -- base_amount 는 양수
  CONSTRAINT ck_compensation_base_positive CHECK (base_amount > 0),

  -- 부양가족은 1 이상 (본인 포함)
  CONSTRAINT ck_compensation_dependents CHECK (dependents >= 1),

  -- simple_rate_option 은 0.80 / 1.00 / 1.20 만
  CONSTRAINT ck_compensation_rate_option CHECK (simple_rate_option IN (0.80, 1.00, 1.20)),

  -- 일용직 + scheme 정합 (EP-712) — 일용직은 DAILY/HOURLY/PIECEWORK 만
  CONSTRAINT ck_compensation_day_laborer_scheme CHECK (
    NOT is_day_laborer OR scheme IN ('DAILY', 'HOURLY', 'PIECEWORK')
  ),

  -- payment_cycle 화이트리스트 (EP-750)
  CONSTRAINT ck_compensation_payment_cycle CHECK (
    payment_cycle IN ('DAILY', 'WEEKLY', 'MONTHLY', 'IMMEDIATE')
  ),

  -- FK
  CONSTRAINT fk_compensation_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_compensation_user         FOREIGN KEY (user_id)         REFERENCES users(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_compensation_created_by   FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- 시점 조회 (가장 빈번)
CREATE INDEX idx_compensation_user_effective ON payroll_compensation_settings (user_id, effective_from DESC);
-- 현재 유효 빠른 조회
CREATE INDEX idx_compensation_active         ON payroll_compensation_settings (user_id) WHERE effective_to IS NULL;
-- 일용직 일괄 조회
CREATE INDEX idx_compensation_day_laborer    ON payroll_compensation_settings (organization_id, is_day_laborer) WHERE is_day_laborer = TRUE;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_compensation_settings              IS 'EP-200~219 사용자별 보수. 변경은 새 row (UPDATE 금지). rules/salary_calc.md.';
COMMENT ON COLUMN payroll_compensation_settings.base_amount  IS 'EP-200 체계별 의미 다름. PIECEWORK 인 경우 base 는 미사용 (task_definitions 사용).';
COMMENT ON COLUMN payroll_compensation_settings.is_short_time IS 'EP-375 60시간 미만 단시간 — 4대보험 가입 제외 분기.';
COMMENT ON COLUMN payroll_compensation_settings.dependents   IS 'EP-381 간이세액 산정용 부양가족 수 (본인 포함).';
COMMENT ON COLUMN payroll_compensation_settings.simple_rate_option IS 'EP-382 간이세액 80%/100%/120% 옵션.';
COMMENT ON COLUMN payroll_compensation_settings.is_day_laborer IS 'EP-710 일용근로자. TRUE 면 day_laborer.md 특례 적용. 게이트 토글 payroll.day_laborer.';
COMMENT ON COLUMN payroll_compensation_settings.payment_cycle  IS 'EP-750 지급 사이클. DAILY/WEEKLY/MONTHLY/IMMEDIATE.';
