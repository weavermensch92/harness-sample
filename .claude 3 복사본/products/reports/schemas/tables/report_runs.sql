-- ════════════════════════════════════════════════════════════════════════
-- report_runs — 보고서 1 회 실행 인스턴스
-- 룰 ER-100 ~ ER-199 / 상세: rules/report_generation.md
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE report_run_status      AS ENUM ('PENDING', 'RUNNING', 'SUCCESS', 'FAILED', 'CANCELLED');
CREATE TYPE report_run_trigger     AS ENUM ('USER', 'SCHEDULE', 'API', 'EVENT');

CREATE TABLE report_runs (
  id                      UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id         UUID                NOT NULL,
  definition_id           UUID                NOT NULL,
  definition_version      SMALLINT            NOT NULL,        -- 실행 시점 정의 버전 (ER-115)
  parameters              JSONB               NOT NULL,
  parameters_hash         VARCHAR(64)         NOT NULL,        -- SHA-256 캐시 키

  status                  report_run_status   NOT NULL DEFAULT 'PENDING',

  -- 실행 메타
  triggered_by            report_run_trigger  NOT NULL,
  triggered_by_user       UUID,
  schedule_id             UUID,                                -- SCHEDULE 트리거 시
  started_at              TIMESTAMPTZ,
  finished_at             TIMESTAMPTZ,
  duration_ms             INTEGER,

  -- 결과 메타
  result_row_count        INTEGER,
  result_file_format      VARCHAR(10),
  result_file_size        INTEGER,
  result_summary          JSONB,

  -- 결과 파일 (외부 storage key, 다운로드 시 signed URL 발급 ER-425)
  result_file_key         TEXT,                                -- 기본 (마스킹)
  result_masked_key       TEXT,
  result_full_key         TEXT,

  -- finalize (ER-160)
  finalized_at            TIMESTAMPTZ,
  is_immutable            BOOLEAN             NOT NULL DEFAULT FALSE,

  -- 에러
  error_message           TEXT,
  error_stack             TEXT,

  meta                    JSONB,
  created_at              TIMESTAMPTZ         NOT NULL DEFAULT now(),

  -- ─── 제약 ───────────────────────────────────────────
  -- 캐시 키 (ER-150). 같은 (org, def, version, params) 동시 실행 방지
  -- (단, 재실행 / catch-up 은 새 row — 비활성 / 무효화된 기존을 회피)
  -- 부분 unique 는 PG 16+ NULLS NOT DISTINCT 지원 시 활용
  CONSTRAINT uq_runs_cache_key UNIQUE (organization_id, definition_id, definition_version, parameters_hash),
  CONSTRAINT ck_runs_finished  CHECK (
    (status IN ('SUCCESS','FAILED','CANCELLED') AND finished_at IS NOT NULL) OR
    (status IN ('PENDING','RUNNING'))
  ),
  CONSTRAINT ck_runs_immutable CHECK (
    (is_immutable AND status = 'SUCCESS' AND finalized_at IS NOT NULL) OR
    NOT is_immutable
  ),
  CONSTRAINT fk_runs_org           FOREIGN KEY (organization_id)    REFERENCES organizations(id)      ON DELETE RESTRICT,
  CONSTRAINT fk_runs_definition    FOREIGN KEY (definition_id)      REFERENCES report_definitions(id) ON DELETE RESTRICT,
  CONSTRAINT fk_runs_user          FOREIGN KEY (triggered_by_user)  REFERENCES users(id)              ON DELETE RESTRICT,
  CONSTRAINT fk_runs_schedule      FOREIGN KEY (schedule_id)        REFERENCES report_schedules(id)   ON DELETE RESTRICT
);

CREATE INDEX idx_runs_org_status     ON report_runs (organization_id, status);
CREATE INDEX idx_runs_pending        ON report_runs (created_at) WHERE status = 'PENDING';
CREATE INDEX idx_runs_finalized      ON report_runs (organization_id) WHERE is_immutable = TRUE;
CREATE INDEX idx_runs_schedule       ON report_runs (schedule_id) WHERE schedule_id IS NOT NULL;
CREATE INDEX idx_runs_finished_at    ON report_runs (finished_at) WHERE finished_at IS NOT NULL;

COMMENT ON TABLE  report_runs                    IS 'ER-110 보고서 실행 인스턴스. 캐시 키 UNIQUE. immutable 결과는 영구 보관 (ER-160).';
COMMENT ON COLUMN report_runs.parameters_hash    IS 'ER-150 SHA-256(stableStringify(parameters)). 캐시 / 멱등 키.';
COMMENT ON COLUMN report_runs.is_immutable       IS 'ER-160 마감 후 immutable. UPDATE / 재생성 차단 (Super 만 강제).';
COMMENT ON COLUMN report_runs.result_full_key    IS 'ER-170 풀 PII 결과. L4+ 권한 다운로드. 시차 마스킹 (ER-435) 시 삭제.';
