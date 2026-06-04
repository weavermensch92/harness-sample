-- ════════════════════════════════════════════════════════════════════════
-- report_feature_flags — 모듈 기능 토글
-- 룰 ER-900 ~ ER-999 / 상세: rules/feature_flags.md
-- (구조는 다른 모듈 feature_flags 와 동일)
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE report_feature_flags (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID         NOT NULL,
  scope_type      VARCHAR(20)  NOT NULL,                -- ORGANIZATION / FACILITY / TEAM
  scope_id        UUID         NOT NULL,
  feature_key     VARCHAR(100) NOT NULL,
  enabled         BOOLEAN      NOT NULL,
  changed_by      UUID         NOT NULL,
  changed_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  reason          TEXT,
  notes           JSONB,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

  CONSTRAINT uq_rep_flags_scope        UNIQUE (organization_id, scope_type, scope_id, feature_key),
  CONSTRAINT ck_rep_flags_scope_type   CHECK (scope_type IN ('ORGANIZATION', 'FACILITY', 'TEAM')),
  CONSTRAINT ck_rep_flags_org_scope_id CHECK (
    scope_type <> 'ORGANIZATION' OR scope_id = organization_id
  ),
  CONSTRAINT ck_rep_flags_key_format   CHECK (
    feature_key ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'
  ),
  CONSTRAINT fk_rep_flags_org          FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_rep_flags_changed_by   FOREIGN KEY (changed_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

CREATE INDEX idx_rep_flags_org_feature ON report_feature_flags (organization_id, feature_key);
CREATE INDEX idx_rep_flags_scope       ON report_feature_flags (scope_type, scope_id);
CREATE INDEX idx_rep_flags_enabled     ON report_feature_flags (organization_id, enabled);

COMMENT ON TABLE  report_feature_flags             IS 'ER-910 reports 기능 토글. 카탈로그 ER-900. rules/feature_flags.md.';
COMMENT ON COLUMN report_feature_flags.feature_key IS '예: report.scheduled_runs / email_distribution / kr_legal_pack.';
