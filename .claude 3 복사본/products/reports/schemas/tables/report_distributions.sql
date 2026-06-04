-- ════════════════════════════════════════════════════════════════════════
-- report_distributions — 보고서 배포 이력
-- 룰 ER-300 ~ ER-399 / 상세: rules/distribution.md
-- 게이트: report.email_distribution / report.api_export
-- ════════════════════════════════════════════════════════════════════════

CREATE TYPE report_dist_channel AS ENUM ('DOWNLOAD', 'EMAIL', 'API', 'SLACK');
CREATE TYPE report_dist_status  AS ENUM ('PENDING', 'SENT', 'FAILED', 'BOUNCED');
CREATE TYPE report_pii_level    AS ENUM ('MASKED', 'FULL');

CREATE TABLE report_distributions (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID                NOT NULL,
  run_id          UUID                NOT NULL,
  channel         report_dist_channel NOT NULL,
  recipients      JSONB               NOT NULL,           -- [{ kind, value, masked }]
  recipients_hash VARCHAR(64)         NOT NULL,           -- SHA-256 (멱등 키)
  pii_level       report_pii_level    NOT NULL DEFAULT 'MASKED',
  status          report_dist_status  NOT NULL DEFAULT 'PENDING',
  error_message   TEXT,
  sent_at         TIMESTAMPTZ,
  delivered_at    TIMESTAMPTZ,                            -- bounce / open 추적
  meta            JSONB,
  created_by      UUID,
  created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),

  -- 멱등 (재발송은 별도 row — 같은 recipients_hash 라도 시점 다르면 별도)
  -- DB 레벨 unique 는 같은 (run, channel, hash, sent_at NULL)에만 적용 — 부분 인덱스
  CONSTRAINT fk_distributions_org      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_distributions_run      FOREIGN KEY (run_id)          REFERENCES report_runs(id)   ON DELETE RESTRICT,
  CONSTRAINT fk_distributions_creator  FOREIGN KEY (created_by)      REFERENCES users(id)         ON DELETE RESTRICT
);

-- 같은 (run, channel, hash) 발송 PENDING 중복 방지
CREATE UNIQUE INDEX uq_distributions_pending
  ON report_distributions (run_id, channel, recipients_hash)
  WHERE status = 'PENDING';

CREATE INDEX idx_distributions_run        ON report_distributions (run_id);
CREATE INDEX idx_distributions_org_status ON report_distributions (organization_id, status);
CREATE INDEX idx_distributions_failed     ON report_distributions (organization_id, status) WHERE status IN ('FAILED', 'BOUNCED');

COMMENT ON TABLE  report_distributions             IS 'ER-310 배포 이력. 채널별 수신자 / 상태. 재발송은 별도 row (ER-380).';
COMMENT ON COLUMN report_distributions.recipients  IS 'ER-315 채널별 형식. 풀 PII 외부 발송은 강화 audit (ER-365).';
COMMENT ON COLUMN report_distributions.pii_level   IS 'MASKED / FULL. FULL 외부 발송은 L4+ 필요.';
