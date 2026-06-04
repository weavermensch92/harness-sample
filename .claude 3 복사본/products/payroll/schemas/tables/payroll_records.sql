-- ════════════════════════════════════════════════════════════════════════
-- payroll_records — 월별 급여 계산 결과
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-260 ~ EP-289 / 상세: rules/salary_calc.md
--
-- 핵심 원칙:
--   • 1 row per (user_id, month, version) — 정정 시 새 version
--   • 상태 머신: DRAFT → FINALIZED → PAID / VOIDED. FINALIZED 이후 수정 금지
--   • 자식: payroll_allowances (1:N) + payroll_deductions (1:N) + payroll_payments (1:N)
--   • 합계 정합 (EP-391): total_deduction = SUM(payroll_deductions.amount)
-- ════════════════════════════════════════════════════════════════════════

-- ─── ENUM ─────────────────────────────────────────────
CREATE TYPE payroll_record_status AS ENUM (
  'DRAFT',      -- 계산만, 미확정
  'FINALIZED',  -- 확정 (수정 금지, 지급 대기)
  'PAID',       -- 지급 완료
  'VOIDED'      -- 무효화 (정정용 새 version 발행됨)
);

-- ─── 테이블 ───────────────────────────────────────────
CREATE TABLE payroll_records (
  id              UUID                  PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope
  organization_id UUID                  NOT NULL,
  user_id         UUID                  NOT NULL,

  -- 기간 / 버전 (EP-260)
  -- v0.11: period_type 도입으로 일/주/월/단가 단위 다양화
  period_type     VARCHAR(10)           NOT NULL DEFAULT 'MONTHLY',  -- MONTHLY/WEEKLY/DAILY/PIECE
  period_key      VARCHAR(20)           NOT NULL,                    -- MONTHLY='YYYY-MM', DAILY='YYYY-MM-DD', WEEKLY='YYYY-Www', PIECE='task_code:date'
  month           CHAR(7),                                            -- 호환용 (period_type='MONTHLY' 면 period_key 와 동일)
  version         INTEGER               NOT NULL DEFAULT 1,

  -- 일용직 record 표시 (EP-725)
  -- 종합과세 / 연말정산 제외 분기
  is_day_laborer_record BOOLEAN         NOT NULL DEFAULT FALSE,

  -- 보수 체계 스냅샷 (해당 월 시작 시점)
  scheme          compensation_scheme   NOT NULL,
  base_amount     NUMERIC(12, 0)        NOT NULL,                  -- 시점 base_amount
  ordinary_hourly NUMERIC(12, 2)        NOT NULL,                  -- EP-220 통상임금 시급

  -- 근무 실적
  worked_minutes  INTEGER               NOT NULL DEFAULT 0,        -- 시급제 / 시간외용
  worked_days     INTEGER               NOT NULL DEFAULT 0,        -- 일급제 / 출근율용

  -- 금액 (KRW 정수)
  base_payment    NUMERIC(12, 0)        NOT NULL,                  -- 본급 (체계별 계산)
  total_allowance NUMERIC(12, 0)        NOT NULL DEFAULT 0,        -- = SUM(allowances)
  total_deduction NUMERIC(12, 0)        NOT NULL DEFAULT 0,        -- = SUM(deductions)
  net_payment     NUMERIC(12, 0)        NOT NULL,                  -- 실 지급액

  -- 상태 (EP-270)
  status          payroll_record_status NOT NULL DEFAULT 'DRAFT',
  finalized_at    TIMESTAMPTZ,
  finalized_by    UUID,
  paid_at         TIMESTAMPTZ,
  voided_at       TIMESTAMPTZ,
  voided_reason   TEXT,

  -- 멱등성 (EP-265): 입력 해시
  -- 같은 입력 (compensation + attendance + work_logs + allowances + deductions)
  -- 재계산 시 같은 hash → skip / 다른 hash → 새 version
  input_hash      CHAR(64),

  -- 공통 컬럼
  created_at      TIMESTAMPTZ           NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ           NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- v0.11: period_type 별 UNIQUE
  CONSTRAINT uq_records_user_period_version UNIQUE (user_id, period_type, period_key, version),

  -- 호환: 기존 month 가 있으면 period_type='MONTHLY' 면 일치
  CONSTRAINT ck_records_month_period CHECK (
    period_type <> 'MONTHLY' OR month = period_key
  ),

  -- period_type 화이트리스트
  CONSTRAINT ck_records_period_type CHECK (period_type IN ('MONTHLY', 'WEEKLY', 'DAILY', 'PIECE')),

  -- period_key 형식 (간단 검증)
  CONSTRAINT ck_records_period_key_format CHECK (
    (period_type = 'MONTHLY' AND period_key ~ '^\d{4}-\d{2}$') OR
    (period_type = 'DAILY'   AND period_key ~ '^\d{4}-\d{2}-\d{2}$') OR
    (period_type = 'WEEKLY'  AND period_key ~ '^\d{4}-W\d{2}$') OR
    (period_type = 'PIECE'   AND length(period_key) > 0)
  ),

  -- 기존 month 형식 검증 (NULL 허용 — DAILY/WEEKLY/PIECE 인 경우)
  CONSTRAINT ck_records_month_format CHECK (month IS NULL OR month ~ '^\d{4}-\d{2}$'),

  -- 금액 음수 금지
  CONSTRAINT ck_records_base_nonneg        CHECK (base_payment >= 0),
  CONSTRAINT ck_records_allowance_nonneg   CHECK (total_allowance >= 0),
  CONSTRAINT ck_records_deduction_nonneg   CHECK (total_deduction >= 0),

  -- net = base + allowance - deduction (애플리케이션 검증, DB 는 형식만)
  -- (음수 net 은 환수 차감 시 가능 — net_payment 자체는 0 이상 강제 안 함)

  -- 상태 정합 (FINALIZED 이상은 finalized_at 필수)
  CONSTRAINT ck_records_finalized_meta CHECK (
    status NOT IN ('FINALIZED', 'PAID', 'VOIDED') OR finalized_at IS NOT NULL
  ),
  CONSTRAINT ck_records_paid_meta CHECK (
    status <> 'PAID' OR paid_at IS NOT NULL
  ),
  CONSTRAINT ck_records_voided_meta CHECK (
    status <> 'VOIDED' OR (voided_at IS NOT NULL AND voided_reason IS NOT NULL)
  ),

  -- worked_minutes / worked_days 음수 금지
  CONSTRAINT ck_records_worked_nonneg CHECK (worked_minutes >= 0 AND worked_days >= 0),

  -- FK
  CONSTRAINT fk_records_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_records_user         FOREIGN KEY (user_id)         REFERENCES users(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_records_finalized_by FOREIGN KEY (finalized_by)    REFERENCES users(id)         ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- 본인 / 기간별 조회 (v0.11: period 기반)
CREATE INDEX idx_records_user_period   ON payroll_records (user_id, period_type, period_key DESC);
-- 호환: month 기반 (정규직 월급 조회)
CREATE INDEX idx_records_user_month    ON payroll_records (user_id, month DESC) WHERE month IS NOT NULL;
-- 조직 단위 (지급 배치)
CREATE INDEX idx_records_org_period    ON payroll_records (organization_id, period_type, period_key);
-- 상태별 (FINALIZED 인 것 중 미지급 추출)
CREATE INDEX idx_records_status        ON payroll_records (status);
-- 같은 (user, period) 의 최신 version 빠른 조회
CREATE INDEX idx_records_latest        ON payroll_records (user_id, period_type, period_key, version DESC);
-- 일용직 record 빠른 추출 (분기 신고용)
CREATE INDEX idx_records_day_laborer   ON payroll_records (organization_id, is_day_laborer_record, period_key) WHERE is_day_laborer_record = TRUE;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_records                  IS 'EP-260~289 급여 계산. v0.11 부터 period_type 으로 일/주/월/단가 다양화. rules/salary_calc.md.';
COMMENT ON COLUMN payroll_records.period_type      IS 'EP-260 보강. MONTHLY=정규직 / DAILY=일용직 / WEEKLY=주급 / PIECE=단가단위.';
COMMENT ON COLUMN payroll_records.period_key       IS 'period_type 별 키. MONTHLY=YYYY-MM / DAILY=YYYY-MM-DD / WEEKLY=YYYY-Www.';
COMMENT ON COLUMN payroll_records.month            IS '호환 컬럼. period_type=MONTHLY 인 경우 period_key 와 동일. DAILY/WEEKLY/PIECE 면 NULL.';
COMMENT ON COLUMN payroll_records.is_day_laborer_record IS 'EP-725 일용직 record. 종합과세/연말정산 제외 분기.';
COMMENT ON COLUMN payroll_records.ordinary_hourly  IS 'EP-220 통상임금 시급 스냅샷. 수당 계산의 베이스.';
COMMENT ON COLUMN payroll_records.input_hash       IS 'EP-265 계산 멱등 — 같은 hash 면 재계산 skip.';
COMMENT ON COLUMN payroll_records.net_payment      IS '실 지급액. 환수 차감 시 음수 가능 (다음 달 정정).';
