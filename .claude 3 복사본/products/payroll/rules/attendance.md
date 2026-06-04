# 근태 (Attendance)

> **ID 범위**: EP-001 ~ EP-099
> **주제**: 출퇴근 기록 / 휴게 / 결근 / 지각 / 조퇴
> **상위**: `INDEX.md`

---

## TL;DR

- **출근/퇴근은 분 단위 기록**. 초 절삭. UTC 저장 / Asia/Seoul 표시.
- **하루 1 row** (`payroll_attendance` 테이블, `(user_id, date)` unique). 다중 출퇴근은 `breaks` JSON 배열에 누적.
- **자동 출퇴근 보정 금지** (MUST). 누락은 본인 신청 → L2 승인 → 감사 로그.
- **휴게 시간은 명시 차감**. 4시간 연속 근무 시 30분, 8시간 연속 근무 시 1시간 휴게 의무 (한국 근로기준법 §54).
- **지각 / 조퇴 / 결근은 status 가 아닌 계산 결과**. 출근 시각 vs 근무 시작 시각으로 파생.
- **본인 작성 / L2+ 조회 / L3 수정**. 마스킹 대상 아님 (시각 자체는 비민감).

핵심 ID: EP-010 (1일 1row) / EP-020 (자동 보정 금지) / EP-040 (휴게 차감) / EP-060 (보정 워크플로)

---

## 1. 기록 모델 (EP-001 ~ EP-019)

### EP-001. 데이터 단위 (MUST)

근태는 **사용자 + 일자** 단위. `payroll_attendance(user_id, date)` 가 자연 키.

```sql
CREATE TABLE payroll_attendance (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  facility_id     UUID NOT NULL,
  team_id         UUID NOT NULL,
  user_id         UUID NOT NULL,
  date            DATE NOT NULL,             -- 조직 timezone 기준 일자
  check_in_at     TIMESTAMPTZ,               -- 첫 출근
  check_out_at    TIMESTAMPTZ,               -- 마지막 퇴근
  breaks          JSONB DEFAULT '[]'::jsonb, -- [{start, end, reason}]
  source          VARCHAR(20) NOT NULL,      -- 'self' / 'gate' / 'manual_admin'
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  UNIQUE (user_id, date)
);
```

### EP-002. 분 단위 절삭 (MUST)

기록 시각의 초 단위는 절삭 (truncate, 반올림 X).

```typescript
// ✅ 정답
const checkIn = new Date(Math.floor(now.getTime() / 60000) * 60000);

// ❌ 금지 — 반올림은 노동 분쟁 소지
const checkIn = roundToMinute(now);
```

### EP-010. 하루 1 row 원칙 (MUST)

같은 사람 / 같은 날에 출퇴근이 여러 번 있어도 row 는 1개. 외출 / 점심 등은 `breaks` 배열에 누적.

```json
{
  "breaks": [
    { "start": "2026-04-28T03:00:00Z", "end": "2026-04-28T04:00:00Z", "reason": "lunch" },
    { "start": "2026-04-28T07:00:00Z", "end": "2026-04-28T07:15:00Z", "reason": "rest" }
  ]
}
```

이유: 일별 집계 / 임금 계산 / 보고서가 `(user_id, date)` 기준.

### EP-011. 일자 경계 (MUST, KR)

야간 근무로 자정 넘기면 **출근일 기준**으로 1 row 에 통합. `date` = check_in_at 의 조직 timezone 일자.

```
출근 04-28 22:00 / 퇴근 04-29 06:00
→ date='2026-04-28', check_in_at='...22:00Z', check_out_at='...06:00Z'
→ 04-29 row 는 생성하지 않음
```

### EP-015. source 필드 (MUST)

| 값 | 의미 | 권한 | 감사 |
|---|---|---|---|
| `self` | 본인이 앱/웹에서 직접 기록 | 본인만 | 일반 |
| `gate` | 출입 게이트 / 비콘 자동 기록 | 시스템 | 일반 |
| `manual_admin` | L2+ 가 보정 입력 | L2+ | **immutable + reason 필수** |

`manual_admin` 은 `notes` 에 보정 사유 필수. 미입력 시 INSERT 거부 (CHECK 제약).

---

## 2. 자동화 / 무결성 (EP-020 ~ EP-039)

### EP-020. 자동 출퇴근 보정 금지 (MUST)

시스템이 임의로 출퇴근 시각을 채우거나 수정하지 않는다. 누락은 누락 그대로 유지하고 보정 워크플로 (EP-060) 로 처리.

이유: 노동시간은 분쟁 시 법적 증거. 자동 채움은 위변조 위험.

```typescript
// ❌ 절대 금지
if (!attendance.check_out_at) {
  attendance.check_out_at = endOfWorkday(attendance.date);
}

// ✅ 정답: 누락 그대로 두고 UI에서 "결근 처리 / 보정 신청" 버튼 노출
```

### EP-025. 동일일 중복 출근 차단 (MUST)

`(user_id, date)` UNIQUE. 같은 날 두 번째 출근 호출은 INSERT 가 아니라 `breaks` 배열 append + check_out_at 갱신.

### EP-030. 시계 신뢰 (MUST)

출퇴근 시각의 권위 있는 출처는 **서버 시계** (`now()`). 클라이언트 전송 시각은 참고용. 클라이언트 시각이 서버 시각보다 5분 이상 차이 나면 거부.

```typescript
const skewMs = Math.abs(clientTime.getTime() - serverNow.getTime());
if (skewMs > 5 * 60 * 1000) {
  throw new ClockSkewError('클라이언트 시계 차이가 큽니다. 새로고침 후 재시도하세요.');
}
```

---

## 3. 휴게 시간 (EP-040 ~ EP-049)

### EP-040. 의무 휴게 (MUST, KR)

근로기준법 §54 의무:
- 4시간 이상 연속 근무 → 30분 이상 휴게
- 8시간 이상 연속 근무 → 1시간 이상 휴게

집계 시 `breaks` 배열에서 휴게 시간 합산을 자동으로 차감. 의무 휴게 미충족이면 audit 경고.

### EP-041. 휴게 시간 차감 (MUST)

근무 시간 = `check_out_at - check_in_at - sum(breaks)`.

```typescript
function netMinutes(att: Attendance): number {
  const gross = (att.check_out_at - att.check_in_at) / 60000;
  const breakMin = att.breaks.reduce((s, b) => s + (b.end - b.start) / 60000, 0);
  return Math.max(0, Math.floor(gross - breakMin));
}
```

### EP-045. 자동 휴게 추정 금지 (MUST)

휴게 기록이 없으면 **0분**으로 처리. 시스템이 임의로 "점심 1시간 차감" 같은 자동 추정 금지. 근로자 불이익.

---

## 4. 결근 / 지각 / 조퇴 (EP-050 ~ EP-059)

### EP-050. 파생 상태 (MUST)

`absent` / `late` / `early_leave` 는 별도 컬럼이 아니라 **계산 결과**. 팀 / 시설의 근무 시간표 (workSchedule) 와 비교해서 도출.

```typescript
function deriveStatus(att: Attendance, schedule: WorkSchedule) {
  if (!att.check_in_at) return 'absent';
  if (att.check_in_at > schedule.startAt) return 'late';
  if (att.check_out_at && att.check_out_at < schedule.endAt) return 'early_leave';
  return 'present';
}
```

이유: 근무 시간표가 변경되면 과거 상태도 일관되게 재계산되어야 함. 컬럼 저장 시 sync 부담.

### EP-055. 휴가 / 공가 / 출장 (SHOULD)

휴가 / 공가 / 출장은 **별도 leave_records 테이블** 로 관리. attendance 와는 join 으로 조회.

`payroll_attendance.notes` 에 휴가 사유를 적는 식의 패턴은 금지.

---

## 5. 보정 워크플로 (EP-060 ~ EP-079)

### EP-060. 누락 / 오기록 보정 (MUST)

본인이 직접 수정 불가. 신청 → 승인 절차:

```
1. 본인 — "출근 누락 신청" 작성 (사유 + 증빙)
2. L2 Supervisor — 승인 / 반려
3. 승인 시 — manual_admin source 로 INSERT/UPDATE
4. audit_logs immutable 기록 (신청자 / 승인자 / 사유 / 변경 전후)
```

### EP-065. 변경 이력 보존 (MUST)

`payroll_attendance` 의 UPDATE 는 변경 전 값을 `audit_logs.metadata.before` 에 기록. 단순 덮어쓰기 금지.

### EP-070. 마감 후 수정 (MUST)

해당 월의 WorkLog 가 `AGGREGATED` 상태로 전이된 후에는 attendance 도 수정 잠금. 정정은 다음 달 조정 트랜잭션 (EP-130 참조).

---

## 6. 권한 / 감사 (EP-080 ~ EP-099)

### EP-080. 권한 매트릭스

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 출퇴근 기록 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 본인 근태 조회 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 팀원 근태 조회 | ❌ | ✅ | ✅ | ✅ | ✅ |
| 본인 보정 신청 | ✅ | ✅ | ✅ | ✅ | ❌ |
| 보정 승인 | ❌ | ✅ (팀) | ✅ | ✅ | ⚠️ |
| 직접 보정 입력 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 마감 후 수정 | ❌ | ❌ | ❌ | ✅ | ⚠️ |

### EP-090. 감사 로그 (MUST)

- 본인 외 근태 조회 → audit (read)
- 모든 보정 / 수정 → audit (write, before/after)
- 마감 후 수정 → audit + Slack 알림 (선택)

actor 가 null 인 경우 (시스템 게이트 자동 입력) 도 source 명시.

---

## 7. 모듈 외부 연동 (EP-100 으로 위임)

근태 자체는 외부 이벤트를 발행하지 않는다. 발행은 `work_log` 단위. attendance → work_log 변환은 EP-100 / EP-200 참조.

---

## 8. 참조

- 권한: `../../../rules/permissions.md` § E-420
- 감사: `../../../rules/database.md` § E-222
- 작업 시간 변환: `work_log.md`
- 급여 계산: `salary_calc.md`
- 스키마: `../schemas/tables/payroll_attendance.sql`
