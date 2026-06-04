-- ════════════════════════════════════════════════════════════════════════
-- payroll_feature_flags — 모듈 기능 토글
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-900 ~ EP-999 / 상세: rules/feature_flags.md
--
-- 핵심 원칙:
--   • UNIQUE (organization_id, scope_type, scope_id, feature_key) — 1 row 1 토글
--   • 변경은 UPDATE (이력은 audit_logs 활용 또는 별도 history 테이블 Phase 1+)
--   • 스코프 우선순위 (EP-911): TEAM > FACILITY > ORGANIZATION > 기본값
--   • feature_key 화이트리스트는 애플리케이션 레벨 (EP-900 카탈로그)
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE payroll_feature_flags (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope (EP-911 우선순위)
  organization_id UUID         NOT NULL,
  scope_type      VARCHAR(20)  NOT NULL,                    -- 'ORGANIZATION' / 'FACILITY' / 'TEAM'
  scope_id        UUID         NOT NULL,                    -- ORGANIZATION 이면 organization_id 와 동일

  -- 기능 식별자 (EP-901 명명 규약)
  -- 예: 'payroll.day_laborer', 'payroll.piecework', 'payroll.firmbanking_provider'
  feature_key     VARCHAR(100) NOT NULL,

  -- 활성 여부
  enabled         BOOLEAN      NOT NULL,

  -- 변경 메타
  changed_by      UUID         NOT NULL,                    -- L4 / Super
  changed_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  reason          TEXT,                                      -- EP-935 권장
  notes           JSONB,                                     -- 의존성 함께 켜진 정보 등

  -- 공통 컬럼
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- 같은 (org, scope, feature) 는 1 row
  CONSTRAINT uq_feature_flags_scope UNIQUE (organization_id, scope_type, scope_id, feature_key),

  -- scope_type 화이트리스트
  CONSTRAINT ck_feature_flags_scope_type CHECK (scope_type IN ('ORGANIZATION', 'FACILITY', 'TEAM')),

  -- ORGANIZATION 스코프면 scope_id = organization_id 일치 (정합)
  CONSTRAINT ck_feature_flags_org_scope_id CHECK (
    scope_type <> 'ORGANIZATION' OR scope_id = organization_id
  ),

  -- feature_key 형식: 영소문자 / 숫자 / 점 / 언더스코어만
  CONSTRAINT ck_feature_flags_key_format CHECK (
    feature_key ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'
  ),

  -- FK
  CONSTRAINT fk_feature_flags_organization FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_feature_flags_changed_by   FOREIGN KEY (changed_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- 런타임 조회 (가장 빈번): org + feature 별
CREATE INDEX idx_feature_flags_org_feature ON payroll_feature_flags (organization_id, feature_key);
-- 스코프 단위 조회
CREATE INDEX idx_feature_flags_scope       ON payroll_feature_flags (scope_type, scope_id);
-- 활성 / 비활성 빠른 필터
CREATE INDEX idx_feature_flags_enabled     ON payroll_feature_flags (organization_id, enabled);

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_feature_flags             IS 'EP-910 모듈 기능 토글. 스코프 우선순위 EP-911. rules/feature_flags.md.';
COMMENT ON COLUMN payroll_feature_flags.feature_key IS 'EP-901 {module}.{subkey} 형식. 카탈로그는 룰 EP-900.';
COMMENT ON COLUMN payroll_feature_flags.scope_type  IS 'EP-911 ORGANIZATION/FACILITY/TEAM. TEAM > FACILITY > ORGANIZATION 우선순위.';
COMMENT ON COLUMN payroll_feature_flags.reason      IS 'EP-935 변경 사유. 형식상 NULLable 이나 UI 에서 입력 강제 권고.';
