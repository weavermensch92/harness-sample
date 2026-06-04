-- ════════════════════════════════════════════════════════════════════════
-- payroll_payments — 지급 트랜잭션 (record 자식, 시도별)
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-500 ~ EP-599 / 상세: rules/payment.md
--
-- 핵심 원칙:
--   • record 1 : N payments. attempt 별 row (재시도 추적)
--   • UNIQUE (record_id, attempt) — 동시 시도 race 차단 (EP-530)
--   • 본인 명의 검증 (EP-535) — 애플리케이션 레벨에서 account_holder vs user.name
--   • 자동 재시도 금지 (EP-545) — 운영자 명시적 액션으로만 새 attempt
--   • PENDING_VERIFICATION 자동 전이 금지 (EP-570) — 수동 확인만
-- ════════════════════════════════════════════════════════════════════════

-- ─── ENUM ─────────────────────────────────────────────
CREATE TYPE payment_status AS ENUM (
  'INITIATED',             -- 이체 시도 중 (Saga Step 2 진행)
  'SUCCESS',               -- 이체 완료 (확정)
  'FAILED',                -- 명확한 실패 (보상 가능 — record FINALIZED 로 롤백)
  'PENDING_VERIFICATION',  -- 불확정 (타임아웃 등) — 운영자 수동 확인 필요
  'CANCELLED'              -- 사전 취소 (이체 호출 전)
);

-- ─── 테이블 ───────────────────────────────────────────
CREATE TABLE payroll_payments (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  -- record 자식
  record_id       UUID            NOT NULL,
  user_id         UUID            NOT NULL,                  -- 빠른 조회용 비정규화

  -- 시도 번호 (EP-530)
  -- 같은 record 의 재시도는 새 attempt
  attempt         INTEGER         NOT NULL DEFAULT 1,

  -- 금액 (KRW 정수 — 이체 직전 record.net_payment 스냅샷)
  amount          NUMERIC(12, 0)  NOT NULL,

  -- 이체 대상 계좌 (EP-535 본인 명의 검증)
  bank_code       VARCHAR(10)     NOT NULL,                  -- 표준 은행 코드 (3자리 + 은행별 자체)
  account_number  VARCHAR(50)     NOT NULL,                  -- 마스킹 표시는 별도 (응답 직전)
  account_holder  VARCHAR(100)    NOT NULL,                  -- 예금주명

  -- 상태 (EP-525)
  status          payment_status  NOT NULL DEFAULT 'INITIATED',

  -- 외부 참조
  bank_ref        VARCHAR(100),                              -- 은행 트랜잭션 ID
  bank_provider   VARCHAR(20)     NOT NULL,                  -- 'mock' / 'firmbanking' / 'openbanking' / 'stripe'

  -- 지급 사이클 스냅샷 (EP-750)
  -- compensation_settings.payment_cycle 의 사본. 설정 변경에 영향 안 받음.
  payment_cycle   VARCHAR(10)     NOT NULL DEFAULT 'MONTHLY', -- DAILY/WEEKLY/MONTHLY/IMMEDIATE

  -- 시점
  initiated_at    TIMESTAMPTZ     NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ,                                -- SUCCESS 또는 FAILED 시점
  failed_reason   TEXT,
  verified_by     UUID,                                       -- PENDING_VERIFICATION 해소한 운영자
  verified_at     TIMESTAMPTZ,

  -- 승인 / 메타
  created_by      UUID            NOT NULL,                   -- 지급 승인자 (L4)
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- 멱등 / 동시 차단 (EP-530)
  CONSTRAINT uq_payments_record_attempt UNIQUE (record_id, attempt),

  -- 시도 번호는 1 이상
  CONSTRAINT ck_payments_attempt_positive CHECK (attempt >= 1),

  -- 금액은 양수 (지급)
  CONSTRAINT ck_payments_amount_positive CHECK (amount > 0),

  -- bank_provider 화이트리스트
  CONSTRAINT ck_payments_provider CHECK (
    bank_provider IN ('mock', 'firmbanking', 'openbanking', 'stripe')
  ),

  -- payment_cycle 화이트리스트 (EP-750)
  CONSTRAINT ck_payments_payment_cycle CHECK (
    payment_cycle IN ('DAILY', 'WEEKLY', 'MONTHLY', 'IMMEDIATE')
  ),

  -- 상태 정합:
  -- SUCCESS / FAILED 는 completed_at 필수
  CONSTRAINT ck_payments_completed_meta CHECK (
    status NOT IN ('SUCCESS', 'FAILED') OR completed_at IS NOT NULL
  ),
  -- FAILED 는 failed_reason 필수
  CONSTRAINT ck_payments_failed_reason CHECK (
    status <> 'FAILED' OR (failed_reason IS NOT NULL AND length(trim(failed_reason)) > 0)
  ),
  -- PENDING_VERIFICATION 해소 (SUCCESS/FAILED 로 전이) 시 verified_by 필수
  -- (실제로는 status 변경 트리거에서 강제. 여기서는 verified_at 만 형식 검증)
  CONSTRAINT ck_payments_verified_pair CHECK (
    (verified_by IS NULL AND verified_at IS NULL) OR (verified_by IS NOT NULL AND verified_at IS NOT NULL)
  ),

  -- FK
  CONSTRAINT fk_payments_record     FOREIGN KEY (record_id)  REFERENCES payroll_records(id) ON DELETE RESTRICT,
  CONSTRAINT fk_payments_user       FOREIGN KEY (user_id)    REFERENCES users(id)           ON DELETE RESTRICT,
  CONSTRAINT fk_payments_creator    FOREIGN KEY (created_by) REFERENCES users(id)           ON DELETE RESTRICT,
  CONSTRAINT fk_payments_verifier   FOREIGN KEY (verified_by) REFERENCES users(id)          ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- record 의 최신 attempt 조회
CREATE INDEX idx_payments_record_attempt ON payroll_payments (record_id, attempt DESC);
-- 본인 지급 이력 조회
CREATE INDEX idx_payments_user_initiated ON payroll_payments (user_id, initiated_at DESC);
-- 운영 대시보드: 미해소 PENDING_VERIFICATION 추적
CREATE INDEX idx_payments_pending        ON payroll_payments (status) WHERE status = 'PENDING_VERIFICATION';
-- 운영 대시보드: 진행 중 INITIATED (오래 머물면 알림)
CREATE INDEX idx_payments_initiated      ON payroll_payments (status, initiated_at) WHERE status = 'INITIATED';
-- bank_ref 역조회 (은행 webhook / 조회)
CREATE INDEX idx_payments_bank_ref       ON payroll_payments (bank_ref) WHERE bank_ref IS NOT NULL;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_payments                IS 'EP-525 지급 트랜잭션. attempt 별 row. Saga 패턴 (EP-520). rules/payment.md.';
COMMENT ON COLUMN payroll_payments.attempt        IS 'EP-530 시도 번호. 같은 record 재시도는 새 attempt. UNIQUE 로 race 차단.';
COMMENT ON COLUMN payroll_payments.account_holder IS 'EP-535 본인 명의 검증 — INSERT 직전 user.name 과 일치 검증.';
COMMENT ON COLUMN payroll_payments.status         IS 'EP-525 PENDING_VERIFICATION 자동 전이 금지 (EP-570) — 운영자 수동 해소만.';
COMMENT ON COLUMN payroll_payments.bank_provider  IS '환경변수 BANK_PROVIDER 와 일치. local/dev=mock 강제 (EP-541).';
COMMENT ON COLUMN payroll_payments.payment_cycle  IS 'EP-750 지급 사이클 스냅샷. 일용직 즉시지급 (DAILY/IMMEDIATE) 분기 식별.';
