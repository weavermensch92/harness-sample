-- ════════════════════════════════════════════════════════════════════════
-- payroll_task_definitions — 업무별 단가 마스터
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-810 ~ EP-819 / 상세: rules/piecework.md
-- 게이트 토글: payroll.piecework (feature_flags.md EP-900). OFF 면 INSERT 도 차단.
--
-- 핵심 원칙:
--   • 작업 단위 (건 / 개 / km / 상자) 별 단가 정의
--   • 시점별 이력 (effective_from / effective_to) — UPDATE 금지, 새 row INSERT
--   • 스코프: facility 우선, fallback to organization (EP-815)
--   • task_code 는 사업장 내 고유 (EP-811)
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE payroll_task_definitions (
  id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope
  organization_id UUID            NOT NULL,
  facility_id     UUID,                                       -- NULL = 조직 전체 적용

  -- 작업 식별
  task_code       VARCHAR(50)     NOT NULL,                   -- 'DELIVERY_3KM', 'BOX_PACK' 등
  task_name       VARCHAR(200)    NOT NULL,                   -- '3km 이내 배송 1건'
  unit            VARCHAR(20)     NOT NULL,                   -- '건' / 'km' / '상자' / '점'

  -- 단가 (KRW 정수)
  unit_price      NUMERIC(12, 0)  NOT NULL,

  -- 시점 (EP-812)
  effective_from  DATE            NOT NULL,
  effective_to    DATE,

  notes           TEXT,
  created_by      UUID            NOT NULL,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- 같은 스코프 / task / 시점은 1 row (이력 무결성)
  CONSTRAINT uq_task_def_scope_code_from UNIQUE (organization_id, facility_id, task_code, effective_from),

  -- task_code 형식: 영문 대문자 / 숫자 / 언더스코어
  CONSTRAINT ck_task_def_code_format CHECK (task_code ~ '^[A-Z][A-Z0-9_]*$'),

  -- 단가 양수
  CONSTRAINT ck_task_def_price_positive CHECK (unit_price > 0),

  -- effective_to 는 from 이후
  CONSTRAINT ck_task_def_effective_range CHECK (effective_to IS NULL OR effective_to >= effective_from),

  -- FK
  CONSTRAINT fk_task_def_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_task_def_facility     FOREIGN KEY (facility_id)     REFERENCES facilities(id)    ON DELETE RESTRICT,
  CONSTRAINT fk_task_def_creator      FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- 시점 조회 (가장 빈번): work_log 생성 시 단가 lookup
CREATE INDEX idx_task_def_lookup        ON payroll_task_definitions (organization_id, task_code, effective_from DESC);
-- facility 우선 조회
CREATE INDEX idx_task_def_facility      ON payroll_task_definitions (facility_id, task_code) WHERE facility_id IS NOT NULL;
-- 현재 활성만 빠른 조회
CREATE INDEX idx_task_def_active        ON payroll_task_definitions (organization_id, task_code) WHERE effective_to IS NULL;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_task_definitions             IS 'EP-810 piecework 단가 마스터. 시점별 이력. rules/piecework.md.';
COMMENT ON COLUMN payroll_task_definitions.task_code   IS 'EP-811 사업장 내 고유. UPPER_SNAKE.';
COMMENT ON COLUMN payroll_task_definitions.unit_price  IS 'EP-812 변경은 새 row. UPDATE 금지 — 과거 work_log 정합성 보존.';
COMMENT ON COLUMN payroll_task_definitions.facility_id IS 'NULL = 조직 전체. facility 정의 우선 (EP-815).';
