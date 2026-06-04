-- ════════════════════════════════════════════════════════════════════════
-- work_logs — 인건비 사실 기록
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-100 ~ EP-199 / 상세: rules/work_log.md
-- boilerplate 정합: prisma WorkLog 모델, business/payroll/handlers/delivery-handler.ts
--
-- 핵심 원칙:
--   • 멱등 2중: processed_events + (source_type, source_id) UNIQUE
--   • amount 는 즉시 확정값 (KRW 정수). 계산은 호출자 책임 (EP-102)
--   • 상태 전이: ACTIVE → CANCELLED / AGGREGATED. AGGREGATED 후 수정 금지
--   • 정정은 새 ADJUSTMENT row (음수/양수 보정, EP-140)
-- ════════════════════════════════════════════════════════════════════════

-- ─── ENUM ─────────────────────────────────────────────
CREATE TYPE work_log_source AS ENUM (
  'DELIVERY',     -- Logistics 배송 완료 이벤트로 생성
  'MANUAL',       -- L3+ 가 직접 입력
  'ATTENDANCE',   -- 근태 → 일급/시급 환산 (Phase 1+ 일배치)
  'ADJUSTMENT',   -- 마감 후 정정 (EP-140)
  'PIECEWORK'     -- 업무별 단가 (EP-820, piecework.md / 게이트: payroll.work_log_piecework_source)
);

CREATE TYPE work_log_status AS ENUM (
  'ACTIVE',       -- 정상
  'CANCELLED',    -- 원 이벤트 취소로 무효화
  'AGGREGATED'    -- 월말 집계 포함됨 (수정 불가)
);

-- ─── 테이블 ───────────────────────────────────────────
CREATE TABLE work_logs (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope (E-430 조직 계층)
  organization_id UUID            NOT NULL,
  facility_id     UUID            NOT NULL,
  team_id         UUID            NOT NULL,
  user_id         UUID            NOT NULL,                   -- 수당 받을 사람

  -- 출처 (EP-101)
  source_type     work_log_source NOT NULL,
  source_id       VARCHAR(100)    NOT NULL,                   -- 자연 키
                                                              --   DELIVERY:   deliveryId
                                                              --   MANUAL:     클라이언트 idempotency key
                                                              --   ATTENDANCE: 'att:{user_id}:{date}'
                                                              --   ADJUSTMENT: 'adj:{original_id}:{seq}'
                                                              --   PIECEWORK:  'pw:{task_code}:{external_ref}'

  -- 금액 (KRW 정수, EP-102)
  -- ADJUSTMENT 만 음수 허용. 다른 source 는 0 이상.
  amount          NUMERIC(12, 0)  NOT NULL,
  date            DATE            NOT NULL,                   -- 발생일 (조직 timezone)

  -- PIECEWORK 산출 메타 (EP-825)
  -- 예: { "task_code": "DELIVERY_3KM", "quantity": 12, "unit_price": 5000, "external_ref": "order_98765" }
  piecework_meta  JSONB,

  -- 상태 (EP-120 머신)
  status          work_log_status NOT NULL DEFAULT 'ACTIVE',

  -- 공통 컬럼 (E-211)
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,

  -- ─── 제약 ───────────────────────────────────────────
  -- 멱등성 (E-820, EP-110): 같은 출처는 한 번만
  CONSTRAINT uq_work_logs_source           UNIQUE (source_type, source_id),

  -- 음수 금액은 ADJUSTMENT 만 (EP-140 보정 row)
  CONSTRAINT ck_work_logs_amount_sign      CHECK (
    source_type = 'ADJUSTMENT' OR amount >= 0
  ),

  -- FK
  CONSTRAINT fk_work_logs_organization     FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_work_logs_facility         FOREIGN KEY (facility_id)     REFERENCES facilities(id)    ON DELETE RESTRICT,
  CONSTRAINT fk_work_logs_team             FOREIGN KEY (team_id)         REFERENCES teams(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_work_logs_user             FOREIGN KEY (user_id)         REFERENCES users(id)         ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- 개인별 시간 범위 조회 (가장 빈번)
CREATE INDEX idx_work_logs_user_date      ON work_logs (user_id, date DESC);
-- 시설 / 팀 단위 집계
CREATE INDEX idx_work_logs_facility_date  ON work_logs (facility_id, date);
CREATE INDEX idx_work_logs_team_date      ON work_logs (team_id, date);
-- 월말 집계 잡 (status='ACTIVE' 필터링)
CREATE INDEX idx_work_logs_status         ON work_logs (status);
-- 소프트 삭제 필터링
CREATE INDEX idx_work_logs_deleted_at     ON work_logs (deleted_at) WHERE deleted_at IS NOT NULL;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  work_logs              IS 'EP-100~199 인건비 사실. 멱등 + 단방향 상태 전이. rules/work_log.md.';
COMMENT ON COLUMN work_logs.amount       IS 'EP-102 즉시 확정 KRW 정수. 시급×시간/단가×수량 계산은 호출자 책임. ADJUSTMENT 만 음수 허용.';
COMMENT ON COLUMN work_logs.source_id    IS 'EP-101 자연 키. DELIVERY=deliveryId / MANUAL=idempotencyKey / ATTENDANCE=att:userId:date / ADJUSTMENT=adj:originalId:seq / PIECEWORK=pw:taskCode:externalRef';
COMMENT ON COLUMN work_logs.status       IS 'EP-120 ACTIVE→CANCELLED/AGGREGATED 단방향. AGGREGATED 후 수정 금지 (EP-140 정정은 ADJUSTMENT row).';
COMMENT ON COLUMN work_logs.piecework_meta IS 'EP-825 PIECEWORK source 인 경우 산출 근거 보존. task_code/quantity/unit_price.';
