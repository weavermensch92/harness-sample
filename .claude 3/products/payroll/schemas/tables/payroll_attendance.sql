-- ════════════════════════════════════════════════════════════════════════
-- payroll_attendance — 근태 (출퇴근 / 휴게)
-- ────────────────────────────────────────────────────────────────────────
-- 룰 EP-001 ~ EP-099 / 상세: rules/attendance.md
--
-- 핵심 원칙:
--   • 1일 1row 강제 — UNIQUE (user_id, date)
--   • 분 단위 절삭 (초 절삭, 반올림 금지)
--   • 자동 보정 금지 — manual_admin source 만 L2+ 가 입력 가능
--   • 휴게는 breaks JSONB 배열에 누적
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE payroll_attendance (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Scope (E-430 조직 계층)
  organization_id UUID         NOT NULL,
  facility_id     UUID         NOT NULL,
  team_id         UUID         NOT NULL,
  user_id         UUID         NOT NULL,

  -- 일자 (조직 timezone 기준, EP-011 야간 근무는 출근일 기준 통합)
  date            DATE         NOT NULL,

  -- 출퇴근 (분 단위 절삭, EP-002)
  check_in_at     TIMESTAMPTZ,
  check_out_at    TIMESTAMPTZ,

  -- 휴게 시간 누적 (EP-040, [{start, end, reason}])
  -- reason: 'lunch' / 'rest' / 'personal' / 'meeting' 등
  breaks          JSONB        NOT NULL DEFAULT '[]'::jsonb,

  -- 입력 출처 (EP-015)
  -- 'self'         : 본인이 직접 기록
  -- 'gate'         : 출입 게이트 / 비콘 자동
  -- 'manual_admin' : L2+ 가 보정 (notes 필수)
  source          VARCHAR(20)  NOT NULL,

  notes           TEXT,

  -- 공통 컬럼 (E-211)
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,

  -- ─── 제약 ───────────────────────────────────────────
  CONSTRAINT pk_payroll_attendance_user_date     UNIQUE (user_id, date),
  CONSTRAINT ck_attendance_source                CHECK (source IN ('self', 'gate', 'manual_admin')),
  -- 보정 입력 시 notes 필수 (EP-015)
  CONSTRAINT ck_attendance_admin_notes_required  CHECK (
    source <> 'manual_admin' OR (notes IS NOT NULL AND length(trim(notes)) > 0)
  ),
  -- check_out 은 check_in 이후
  CONSTRAINT ck_attendance_out_after_in          CHECK (
    check_out_at IS NULL OR check_in_at IS NULL OR check_out_at >= check_in_at
  ),

  -- FK
  CONSTRAINT fk_attendance_organization  FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT fk_attendance_facility      FOREIGN KEY (facility_id)     REFERENCES facilities(id)    ON DELETE RESTRICT,
  CONSTRAINT fk_attendance_team          FOREIGN KEY (team_id)         REFERENCES teams(id)         ON DELETE RESTRICT,
  CONSTRAINT fk_attendance_user          FOREIGN KEY (user_id)         REFERENCES users(id)         ON DELETE RESTRICT
);

-- ─── 인덱스 ───────────────────────────────────────────
-- 본인 조회 (가장 빈번)
CREATE INDEX idx_attendance_user_date     ON payroll_attendance (user_id, date DESC);
-- 팀 / 시설 단위 대시보드
CREATE INDEX idx_attendance_team_date     ON payroll_attendance (team_id, date);
CREATE INDEX idx_attendance_facility_date ON payroll_attendance (facility_id, date);
-- 소프트 삭제 필터링
CREATE INDEX idx_attendance_deleted_at    ON payroll_attendance (deleted_at) WHERE deleted_at IS NOT NULL;

-- ─── 코멘트 ───────────────────────────────────────────
COMMENT ON TABLE  payroll_attendance              IS 'EP-001~099 근태. 1일 1row, 분 단위. rules/attendance.md 참조.';
COMMENT ON COLUMN payroll_attendance.breaks       IS 'EP-040 휴게 시간 [{start, end, reason}]. 자동 추정 금지 (EP-045).';
COMMENT ON COLUMN payroll_attendance.source       IS 'EP-015 입력 출처. manual_admin 은 notes 필수.';
COMMENT ON COLUMN payroll_attendance.date         IS 'EP-011 조직 timezone 기준. 야간 근무는 출근일 기준 통합.';
