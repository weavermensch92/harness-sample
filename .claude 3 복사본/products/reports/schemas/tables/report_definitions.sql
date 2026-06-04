-- ════════════════════════════════════════════════════════════════════════
-- report_definitions — 보고서 메타 / 정의
-- 룰 ER-001 ~ ER-099 / 상세: rules/report_definition.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE report_data_query_kind AS ENUM ('BUILTIN', 'SQL', 'API');

CREATE TABLE report_definitions (
  id                      UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id         UUID,                                  -- NULL = 전사 (built-in)
  code                    VARCHAR(80)             NOT NULL,
  name                    VARCHAR(200)            NOT NULL,
  description             TEXT,

  -- 데이터 소스
  source_modules          TEXT[]                  NOT NULL,      -- ['payroll'] / ['payroll','logistics']
  data_query_kind         report_data_query_kind  NOT NULL,
  query_text              TEXT,                                  -- SQL kind 일 때 본문 (보안 검증)
  query_handler           VARCHAR(200),                          -- BUILTIN kind 일 때 함수명

  -- 파라미터 (JSON Schema)
  parameters_schema       JSONB,

  -- 권한 (ER-080)
  required_permissions    JSONB                   NOT NULL,      -- { payroll: 'L3' }

  -- PII (ER-090)
  pii_columns             JSONB,

  -- 출력
  output_formats          TEXT[]                  NOT NULL DEFAULT ARRAY['xlsx', 'csv'],
  default_format          VARCHAR(10)             NOT NULL DEFAULT 'xlsx',

  -- 보존 (ER-415)
  retention_days          INTEGER                 NOT NULL DEFAULT 365,
  pii_retention_days      INTEGER,
  pii_mask_after_days     INTEGER,

  -- 실행 메타
  estimated_duration_ms   INTEGER,                                -- 비동기 결정용 (ER-130)
  notify_on_failure       BOOLEAN                 NOT NULL DEFAULT TRUE,

  -- 버전 / 활성
  version                 SMALLINT                NOT NULL DEFAULT 1,
  is_active               BOOLEAN                 NOT NULL DEFAULT TRUE,
  is_builtin              BOOLEAN                 NOT NULL DEFAULT FALSE,

  meta                    JSONB,
  created_by              UUID,
  created_at              TIMESTAMPTZ             NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  CONSTRAINT uq_definitions_code_version UNIQUE NULLS NOT DISTINCT (organization_id, code, version),
  CONSTRAINT ck_definitions_code_format  CHECK (code ~ '^[A-Z][A-Z0-9_]{2,79}$'),
  CONSTRAINT ck_definitions_query        CHECK (
    (data_query_kind = 'BUILTIN' AND query_handler IS NOT NULL) OR
    (data_query_kind = 'SQL'     AND query_text    IS NOT NULL) OR
    (data_query_kind = 'API'     AND query_text    IS NOT NULL)
  ),
  CONSTRAINT ck_definitions_retention   CHECK (retention_days > 0),
  CONSTRAINT ck_definitions_default_fmt CHECK (default_format = ANY(output_formats)),
  CONSTRAINT fk_definitions_org         FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_definitions_creator     FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

CREATE INDEX idx_definitions_org_code   ON report_definitions (organization_id, code) WHERE is_active = TRUE;
CREATE INDEX idx_definitions_modules    ON report_definitions USING GIN (source_modules);
CREATE INDEX idx_definitions_builtin    ON report_definitions (is_builtin) WHERE is_builtin = TRUE;

COMMENT ON TABLE  report_definitions               IS 'ER-010 보고서 정의. 변경 시 새 row + 버전 (ER-015). KR 법정은 is_builtin=true.';
COMMENT ON COLUMN report_definitions.source_modules IS 'payroll / inventory / logistics 등. 권한 위임 기반 (ER-080).';
COMMENT ON COLUMN report_definitions.required_permissions IS 'JSON: { module: minLevel }. ER-080 위임 검증.';
COMMENT ON COLUMN report_definitions.pii_columns   IS 'ER-090 PII 매트릭스. [{ column, mask_rule, unmask_level }].';
COMMENT ON COLUMN report_definitions.retention_days IS 'ER-415 결과 보존 일수. KR 법정 5~10년.';
