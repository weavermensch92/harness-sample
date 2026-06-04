# 스케줄 (Scheduling)

> **ID 범위**: ER-200 ~ ER-299
> **주제**: 보고서 자동 실행 (cron / 월말 / 분기말 등)
> **상위**: `INDEX.md`
> **게이트 토글**: `report.scheduled_runs` (기본 ON)

---

## TL;DR

- **report_schedule = 정의 + cron + 파라미터 빌더**.
- **cron 표현식 + timezone (Asia/Seoul 기본)** — 월말 / 분기말 / 매주 월요일 등.
- **파라미터 빌더 (MUST)** — 실행 시점 기준으로 동적 파라미터 생성 (예: 전월 / 전분기).
- **트리거 보정 (MUST)** — 휴일 / 마감 일정 미반영 회피. `payroll.period_closed` 후 24시간 대기.
- **중복 방지 (MUST)** — 같은 schedule 의 실행이 연속될 때 (지연 / 재시도) 중복 금지.
- **활성 / 비활성 토글** — 일시 정지 가능. 변경 audit.
- **실패 시 알림** — 운영자 알림 (이메일 / Slack / 시스템 알림).

핵심 ID: ER-210 (모델) / ER-220 (cron) / ER-230 (파라미터 빌더) / ER-240 (트리거 보정) / ER-250 (중복 방지)

---

## 1. 모델 (ER-200 ~ ER-219)

### ER-210. report_schedules 테이블 (MUST)

```sql
CREATE TABLE report_schedules (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  definition_id   UUID NOT NULL,

  name            VARCHAR(200) NOT NULL,
  cron_expression VARCHAR(50) NOT NULL,            -- '0 1 1 * *' (매월 1일 01:00)
  timezone        VARCHAR(50) NOT NULL DEFAULT 'Asia/Seoul',

  -- 파라미터 빌더
  parameter_builder VARCHAR(50) NOT NULL,          -- 'PREVIOUS_MONTH' / 'PREVIOUS_QUARTER' / 'CUSTOM'
  parameter_builder_config JSONB,

  -- 트리거 보정
  wait_for_period_close BOOLEAN NOT NULL DEFAULT TRUE,
  -- 마감 후 N 시간 대기
  wait_after_close_hours SMALLINT NOT NULL DEFAULT 24,

  -- 활성
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  paused_until    TIMESTAMPTZ,                     -- 일시 정지 (NULL = 정상)

  -- 다음 실행 시점 (cron 계산 결과 캐시)
  next_run_at     TIMESTAMPTZ,
  last_run_at     TIMESTAMPTZ,
  last_run_status VARCHAR(20),

  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### ER-215. cron 표현식 검증 (MUST)

표준 cron (5 필드) — 분 / 시 / 일 / 월 / 요일.

```typescript
import cronParser from 'cron-parser';
function validateCron(expression: string): boolean {
  try {
    cronParser.parseExpression(expression, { tz: 'Asia/Seoul' });
    return true;
  } catch { return false; }
}
```

자주 쓰는 패턴 프리셋:
- `0 1 1 * *` — 매월 1일 01:00 (전월 보고서)
- `0 1 1 1,4,7,10 *` — 매분기 첫 달 1일 01:00 (전분기 보고서)
- `0 1 * * 1` — 매주 월요일 01:00 (전주 보고서)

---

## 2. 스케줄 워커 (ER-220 ~ ER-239) — MUST

### ER-220. cron 폴링 (MUST)

매 분 단위 cron worker:
```typescript
// jobs/scheduled-runs.ts
async function pollSchedules() {
  const now = new Date();
  const schedules = await db.reportSchedule.findMany({
    where: {
      isActive: true,
      OR: [{ pausedUntil: null }, { pausedUntil: { lt: now }}],
      nextRunAt: { lte: now }
    }
  });
  for (const s of schedules) {
    await tryTriggerSchedule(s);
  }
}
```

### ER-225. next_run_at 갱신 (MUST)

실행 직전 계산 + 락 보장 (멱등):
```typescript
async function tryTriggerSchedule(schedule) {
  const interval = cronParser.parseExpression(schedule.cronExpression, { tz: schedule.timezone });
  const next = interval.next().toDate();

  // 다음 실행 예약 (atomic 갱신)
  const updated = await db.reportSchedule.updateMany({
    where: { id: schedule.id, nextRunAt: schedule.nextRunAt },  // 낙관락
    data: { nextRunAt: next, lastRunAt: new Date() }
  });
  if (updated.count === 0) return;   // 다른 인스턴스가 이미 처리

  // 트리거 (트리거 보정 통과 시)
  await checkAndTriggerSchedule(schedule);
}
```

> 분산 환경 (worker 여러 개) 에서 같은 schedule 중복 실행 방지 — DB 낙관락 또는 분산락.

### ER-228. cron 빈도 제한 (MUST)

너무 잦은 실행 방지:
- 분 단위 < 5 분 = 거부
- 동일 정의의 동시 실행 한도 = 1
- 조직별 active 스케줄 한도 = 50 (기본)

---

## 3. 파라미터 빌더 (ER-230 ~ ER-239) — MUST

### ER-230. 표준 빌더 (MUST)

```typescript
type ParameterBuilder =
  | 'PREVIOUS_MONTH'   // 전월 (실행 시점 기준)
  | 'PREVIOUS_QUARTER'
  | 'PREVIOUS_DAY'
  | 'PREVIOUS_WEEK'
  | 'CURRENT_MONTH'
  | 'CUSTOM';

function buildParameters(builder, config, now, timezone) {
  const tzNow = utcToZonedTime(now, timezone);
  switch (builder) {
    case 'PREVIOUS_MONTH': {
      const prev = subMonths(tzNow, 1);
      return { period_year: prev.getFullYear(), period_month: prev.getMonth() + 1 };
    }
    case 'PREVIOUS_QUARTER': {
      const prevQ = getQuarter(subQuarters(tzNow, 1));
      return { period_year: getYear(subQuarters(tzNow, 1)), period_quarter: prevQ };
    }
    case 'PREVIOUS_DAY':  return { snapshot_date: format(subDays(tzNow, 1), 'yyyy-MM-dd') };
    case 'PREVIOUS_WEEK': {
      const start = startOfWeek(subWeeks(tzNow, 1));
      const end = endOfWeek(subWeeks(tzNow, 1));
      return { start_date: format(start, 'yyyy-MM-dd'), end_date: format(end, 'yyyy-MM-dd') };
    }
    case 'CUSTOM': return config.parameters;
  }
}
```

### ER-235. CUSTOM 빌더 (MUST, 보안)

CUSTOM 은 `parameter_builder_config.parameters` 의 정적 JSON. JS 코드 / 표현식 X.

```jsonc
{
  "parameter_builder": "CUSTOM",
  "parameter_builder_config": {
    "parameters": {
      "facility_id": "uuid-...",
      "period_year": "{{previous_year}}",   // 미리 정의된 토큰만 허용
      "period_month": "{{previous_month}}"
    }
  }
}
```

토큰 치환은 화이트리스트만 (`{{previous_*}}`, `{{current_*}}` 등).

---

## 4. 트리거 보정 (ER-240 ~ ER-249) — MUST

### ER-240. 마감 대기 (MUST)

`wait_for_period_close = true` 시 — 데이터 마감 전 실행 회피:

```typescript
async function checkAndTriggerSchedule(schedule) {
  const def = await loadDefinition(schedule.definitionId);
  const params = buildParameters(/* ... */);

  if (schedule.waitForPeriodClose) {
    for (const module of def.sourceModules) {
      const period = inferPeriodFromParams(params);
      const closedAt = await getPeriodCloseTime(module, schedule.organizationId, period);
      if (!closedAt) {
        // 아직 마감 X — 다음 cron 시점에 재시도
        await postponeSchedule(schedule.id);
        return;
      }
      const elapsedHours = differenceInHours(new Date(), closedAt);
      if (elapsedHours < schedule.waitAfterCloseHours) {
        await postponeSchedule(schedule.id);
        return;
      }
    }
  }

  // 트리거
  await startReportRun(def.code, params, /* schedule actor */, { triggeredBy: 'SCHEDULE', scheduleId: schedule.id });
}
```

### ER-245. 휴일 / 주말 회피 (옵션)

`parameter_builder_config.skipWeekends` / `skipKrHolidays`:
- 주말이면 다음 영업일로 연기
- 한국 공휴일 캘린더 연동 (Phase 1+)

---

## 5. 중복 방지 (ER-250 ~ ER-259)

### ER-250. 동일 (schedule, parameters) 중복 (MUST)

```sql
-- report_runs 의 UNIQUE 활용
ALTER TABLE report_runs
  ADD CONSTRAINT uq_runs_schedule_params
  UNIQUE (organization_id, schedule_id, parameters_hash)
  WHERE schedule_id IS NOT NULL;  -- 부분 인덱스
```

같은 schedule + 같은 parameters → 두 번째 INSERT 거부 (멱등).

### ER-255. 누락된 schedule 자동 catch-up (옵션)

서버 다운 / cron worker 정지 후 복구 시:
- 누락된 cron 시점 발견
- catch-up 실행 (옵션) — 정의에 따라 (예: 일일 보고서는 어제만, 월말은 무조건)

---

## 6. 일시 정지 / 재개 (ER-260 ~ ER-269)

### ER-260. paused_until (MUST)

```typescript
async function pauseSchedule(scheduleId, until, reason, actor) {
  await db.$transaction(async (tx) => {
    await tx.reportSchedule.update({ where: { id: scheduleId }, data: { pausedUntil: until }});
    await writeAudit({ action: 'report.schedule.paused', target: scheduleId, actor, metadata: { until, reason }});
  });
}
```

`pausedUntil < now()` 시 자동 재개. NULL = 정상.

### ER-265. is_active = false (MUST)

영구 비활성화 — 다시 켜기 전까지 실행 X. 변경 audit 필수.

---

## 7. 실패 알림 (ER-270 ~ ER-279)

### ER-270. 실패 시 알림 (MUST)

스케줄로 트리거된 run 이 FAILED 시:
- 보고서 정의의 `notify_on_failure` 메타에 따라 운영자 알림
- 이메일 / Slack / in-app
- 연속 실패 (3 회 +) 시 schedule 자동 paused (운영자 개입 필요)

```typescript
async function handleScheduledRunFailure(run) {
  const schedule = await db.reportSchedule.findUnique({ where: { id: run.scheduleId }});
  // 알림
  await notifyOps(`스케줄 ${schedule.name} 실패: ${run.errorMessage}`);

  // 연속 실패 확인
  const recentFailures = await db.reportRun.count({
    where: { scheduleId: schedule.id, status: 'FAILED', createdAt: { gte: subDays(new Date(), 7) }}
  });
  if (recentFailures >= 3) {
    await db.reportSchedule.update({
      where: { id: schedule.id },
      data: { isActive: false }
    });
    await notifyOps(`스케줄 ${schedule.name} 7일내 3회 실패 — 자동 비활성화`);
  }
}
```

---

## 8. 권한 / 감사 (ER-280 ~ ER-299)

### ER-280. 권한

| 작업 | L3 | L4 | Super |
|---|---|---|---|
| 스케줄 조회 | ✅ | ✅ | ✅ |
| 스케줄 생성 / 수정 | ✅ (본인 정의) | ✅ | ✅ |
| 스케줄 일시 정지 | ✅ | ✅ | ✅ |
| 스케줄 영구 비활성화 | ❌ | ✅ | ✅ |
| cron 표현식 < 5분 (예외) | ❌ | ❌ | ✅ |
| 스케줄 강제 즉시 실행 | ✅ | ✅ | ✅ |

### ER-290. 감사

| action | 시점 |
|---|---|
| `report.schedule.created` | 신규 등록 |
| `report.schedule.updated` | cron / 파라미터 변경 |
| `report.schedule.paused` | 일시 정지 |
| `report.schedule.resumed` | 재개 |
| `report.schedule.deactivated` | 비활성화 (수동 / 자동) |
| `report.schedule.triggered` | 자동 트리거 |
| `report.schedule.postponed` | 마감 대기로 연기 |
| `report.schedule.consecutive_failures` | 연속 실패 임계 도달 |

---

## 9. 참조

- 게이트: `feature_flags.md` (`report.scheduled_runs`)
- 정의: `report_definition.md`
- 실행: `report_generation.md` (특히 ER-115)
- 마감 / 캐시 무효화: `report_generation.md` (ER-160, ER-153)
- 스키마: `../schemas/tables/report_schedules.sql`
