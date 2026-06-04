-- ════════════════════════════════════════════════════════════════════════
-- report_schedules — 자동 실행 스케줄
-- 룰 ER-200 ~ ER-299 / 상세: rules/scheduling.md
-- 게이트: report.scheduled_runs
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE report_param_builder AS ENUM (
  'PREVIOUS_MONTH', 'PREVIOUS_QUARTER', 'PREVIOUS_DAY', 'PREVIOUS_WEEK',
  'CURRENT_MONTH', 'CUSTOM'
);

CREATE TABLE report_schedules (
  id                          UUID                  PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id             UUID                  NOT NULL,
  definition_id               UUID                  NOT NULL,

  name                        VARCHAR(200)          NOT NULL,
  cron_expression             VARCHAR(50)           NOT NULL,
  timezone                    VARCHAR(50)           NOT NULL DEFAULT 'Asia/Seoul',

  -- 파라미터 빌더 (ER-230)
  parameter_builder           report_param_builder  NOT NULL,
  parameter_builder_config    JSONB,

  -- 트리거 보정 (ER-240)
  wait_for_period_close       BOOLEAN               NOT NULL DEFAULT TRUE,
  wait_after_close_hours      SMALLINT              NOT NULL DEFAULT 24,

  -- 활성 / 일시 정지
  is_active                   BOOLEAN               NOT NULL DEFAULT TRUE,
  paused_until                TIMESTAMPTZ,

  -- cron 계산 캐시
  next_run_at                 TIMESTAMPTZ,
  last_run_at                 TIMESTAMPTZ,
  last_run_status             VARCHAR(20),
  consecutive_failure_count   SMALLINT              NOT NULL DEFAULT 0,

  created_by                  UUID                  NOT NULL,
  created_at                  TIMESTAMPTZ           NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ           NOT NULL DEFAULT now(),

  CONSTRAINT ck_schedules_wait_hours    CHECK (wait_after_close_hours >= 0 AND wait_after_close_hours <= 168),
  CONSTRAINT ck_schedules_failure_count CHECK (consecutive_failure_count >= 0),
  CONSTRAINT fk_schedules_org           FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_schedules_definition    FOREIGN KEY (definition_id)   REFERENCES report_definitions(id) ON DELETE RESTRICT,
  CONSTRAINT fk_schedules_creator       FOREIGN KEY (created_by)      REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_schedules_active_next  ON report_schedules (next_run_at) WHERE is_active = TRUE;
CREATE INDEX idx_schedules_org_def      ON report_schedules (organization_id, definition_id);
CREATE INDEX idx_schedules_paused       ON report_schedules (paused_until) WHERE paused_until IS NOT NULL;

COMMENT ON TABLE  report_schedules                  IS 'ER-210 자동 실행 스케줄. cron + 파라미터 빌더 + 마감 대기.';
COMMENT ON COLUMN report_schedules.cron_expression  IS '5 필드 cron. 분 < 5 차단 (ER-228). Super 예외.';
COMMENT ON COLUMN report_schedules.timezone         IS 'Asia/Seoul 기본. cron 계산 / 파라미터 빌더 모두 이 timezone.';
COMMENT ON COLUMN report_schedules.parameter_builder IS 'ER-230 PREVIOUS_MONTH 등. CUSTOM 은 화이트리스트 토큰만 허용.';
COMMENT ON COLUMN report_schedules.consecutive_failure_count IS 'ER-270 7일내 3회 실패 시 자동 비활성화.';
