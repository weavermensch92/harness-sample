# 보고서 실행 / 생성 (Report Generation)

> **ID 범위**: ER-100 ~ ER-199
> **주제**: 보고서 실행 (수동 / 스케줄), 결과 저장, 캐싱, 비동기 처리
> **상위**: `INDEX.md`

---

## TL;DR

- **report_run = 1 회 실행 인스턴스** — definition_id, parameters, status, result_file_url, started_at, finished_at.
- **상태 머신**: PENDING → RUNNING → SUCCESS / FAILED / CANCELLED.
- **임계 시간 (예: 30초) 초과 예상 = 비동기** — pending queue 등록 후 즉시 응답. worker 가 처리.
- **결과 보존 (MUST)** — 결과 파일은 외부 storage (S3 / GCS), DB 에 URL + 메타. 재현성 보장.
- **캐싱** — 동일 (definition_version, parameters, snapshot_at) 재실행 시 기존 결과 반환 (옵션).
- **캐시 무효화 (MUST)** — 모듈 데이터 변경 이벤트로 영향 받는 캐시 invalidate.
- **마감 (period_closed) 보고서 = 결과 finalize** — 결과 immutable, 수정 차단.
- **PII 결과 = 권한별 분리 파일** — 마스킹 / 풀 결과를 별도 파일로 저장.

핵심 ID: ER-110 (모델) / ER-120 (lifecycle) / ER-130 (비동기) / ER-150 (캐시) / ER-160 (finalize) / ER-170 (PII 분리)

---

## 1. 모델 (ER-100 ~ ER-119)

### ER-110. report_runs 테이블 (MUST)

```sql
CREATE TABLE report_runs (
  id                  UUID PRIMARY KEY,
  organization_id     UUID NOT NULL,
  definition_id       UUID NOT NULL,
  definition_version  SMALLINT NOT NULL,            -- 실행 시점 정의 버전 (재현)
  parameters          JSONB NOT NULL,
  parameters_hash     VARCHAR(64) NOT NULL,         -- SHA-256 of parameters (캐시 키)

  status              VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  -- PENDING / RUNNING / SUCCESS / FAILED / CANCELLED

  -- 실행 메타
  triggered_by        VARCHAR(20) NOT NULL,        -- USER / SCHEDULE / API / EVENT
  triggered_by_user   UUID,
  schedule_id         UUID,                         -- 스케줄 트리거 시
  started_at          TIMESTAMPTZ,
  finished_at         TIMESTAMPTZ,
  duration_ms         INTEGER,

  -- 결과
  result_row_count    INTEGER,
  result_file_url     TEXT,                         -- 외부 storage signed URL (TTL)
  result_file_format  VARCHAR(10),                  -- xlsx / csv / pdf
  result_file_size    INTEGER,                      -- bytes
  result_summary      JSONB,                        -- 요약 통계 (총합 등)

  -- PII 분리 결과 (ER-170)
  result_masked_url   TEXT,                         -- L3 권한용 (마스킹)
  result_full_url     TEXT,                         -- L4 권한용 (풀)

  -- finalize (ER-160)
  finalized_at        TIMESTAMPTZ,                  -- 마감 시점
  is_immutable        BOOLEAN NOT NULL DEFAULT FALSE,

  -- 에러
  error_message       TEXT,
  error_stack         TEXT,

  meta                JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (organization_id, definition_id, parameters_hash, snapshot_at)
);
```

> ⚠️ snapshot_at 컬럼은 캐시 키의 일부이지만 시점별 보존 의미 — 명시 또는 derived 결정 필요.

### ER-115. 실행 = run row INSERT (MUST)

```typescript
async function startReportRun(definitionCode, parameters, actor) {
  const def = await loadDefinition(definitionCode, actor.orgId);
  await checkReportPermission(def, actor);                   // ER-080
  await validateParameters(def.parametersSchema, parameters); // ER-060
  const paramsHash = sha256(stableStringify(parameters));

  // 캐시 확인 (ER-150)
  const cached = await findValidCachedRun(def.id, def.version, paramsHash, actor.orgId);
  if (cached) return cached;

  const run = await db.reportRun.create({
    data: {
      organizationId: actor.orgId,
      definitionId: def.id,
      definitionVersion: def.version,
      parameters,
      parametersHash: paramsHash,
      status: 'PENDING',
      triggeredBy: 'USER',
      triggeredByUser: actor.id
    }
  });
  await enqueueReportJob(run.id);
  return run;
}
```

---

## 2. Lifecycle (ER-120 ~ ER-139)

### ER-120. 상태 머신 (MUST)

```
PENDING  →  RUNNING  →  SUCCESS
                  ↓
               FAILED  (재시도 가능)
PENDING / RUNNING  →  CANCELLED
SUCCESS  →  (finalize → is_immutable=true)
```

### ER-125. RUNNING 트랜잭션 분리 (MUST)

run 상태 변경은 짧은 트랜잭션. 실 실행은 트랜잭션 외부:
```typescript
async function executeRun(runId) {
  await db.reportRun.update({ where: { id: runId }, data: { status: 'RUNNING', startedAt: new Date() }});
  try {
    const result = await actuallyGenerateReport(runId);  // 외부 트랜잭션 (오래 걸림)
    await db.reportRun.update({
      where: { id: runId },
      data: {
        status: 'SUCCESS', finishedAt: new Date(),
        resultFileUrl: result.url,
        resultRowCount: result.rowCount,
        resultFileSize: result.size
      }
    });
  } catch (e) {
    await db.reportRun.update({
      where: { id: runId },
      data: { status: 'FAILED', finishedAt: new Date(), errorMessage: e.message }
    });
  }
}
```

### ER-128. 재시도 정책 (MUST)

- FAILED → 사용자 / 자동 재시도 가능
- 자동 재시도 한도 = 3 회 (cron / 스케줄 기반)
- 동일 입력 재시도 = 새 run row INSERT (이력 보존)

---

## 3. 비동기 처리 (ER-130 ~ ER-149) — MUST

### ER-130. 임계 결정 (MUST)

작은 보고서 (예상 < 5초): 동기 (즉시 결과)
중간 (5~30초): 비동기 + 자동 폴링
큰 (30초+): 무조건 비동기 + 완료 알림

추정 방법:
- 정의 메타에 `estimated_duration_ms`
- 또는 과거 실행 평균 (`AVG(duration_ms)`)

```typescript
async function decideExecutionMode(def, parameters) {
  const estimated = await estimateDuration(def, parameters);
  if (estimated < 5_000) return 'SYNC';
  if (estimated < 30_000) return 'ASYNC_AUTO_POLL';
  return 'ASYNC_NOTIFY';
}
```

### ER-135. 큐 / Worker (MUST)

- 큐: `report_jobs` (BullMQ / DB-based queue / SQS 등)
- worker: 별도 프로세스 / 컨테이너
- concurrency: 조직별 동시 실행 한도 (예: 5)
- 우선순위: USER > SCHEDULE > API > EVENT

### ER-140. 진행 상태 / 알림 (MUST)

- 폴링: GET /report-runs/:id → status
- WebSocket / SSE (옵션, Phase 2+)
- 완료 알림: 이메일 (`report.email_distribution=ON` 시) 또는 in-app notification

### ER-145. CANCELLED 처리 (MUST)

PENDING / RUNNING 상태에서 사용자 취소 가능:
- PENDING: 큐에서 제거
- RUNNING: 실행 worker 에 시그널 (best-effort), 결과 무시
- 이미 SUCCESS / FAILED → 취소 불가

---

## 4. 캐싱 (ER-150 ~ ER-159)

### ER-150. 캐시 키 (MUST)

`(organization_id, definition_id, definition_version, parameters_hash)` UNIQUE.

같은 키의 SUCCESS run 이 있으면 재실행 X. 단, 다음 조건 충족 시:
- 캐시 토글 ON (`report.cache_aggressive`)
- 캐시 유효 (관련 모듈 데이터 변경 이벤트 미발생)
- finalized 또는 마감일 이전 데이터

### ER-153. 캐시 무효화 이벤트 (MUST)

```typescript
async function handleModuleEvent(event) {
  switch (event.type) {
    case 'payroll.payment.confirmed':
      await invalidateRunsByModule('payroll', event.organizationId, event.periodKey);
      break;
    case 'inventory.balance.adjusted':
      await invalidateRunsByModule('inventory', event.organizationId, event.warehouseId);
      break;
    case 'logistics.delivery.completed':
      await invalidateRunsByModule('logistics', event.organizationId, event.deliveryDate);
      break;
  }
}

async function invalidateRunsByModule(module, orgId, key) {
  await db.reportRun.updateMany({
    where: {
      organizationId: orgId,
      isImmutable: false,
      definition: { sourceModules: { has: module }},
      // 추가: parameters 가 영향 범위와 겹침
    },
    data: { meta: { cacheInvalidated: true, invalidatedAt: new Date() }}
  });
}
```

> 무효화는 row 자체를 삭제하지 않음 (감사 / 재현 보존). meta 플래그만.

### ER-155. 캐시 hit 검증 (MUST)

```typescript
async function findValidCachedRun(defId, version, paramsHash, orgId) {
  const r = await db.reportRun.findFirst({
    where: {
      organizationId: orgId,
      definitionId: defId,
      definitionVersion: version,
      parametersHash: paramsHash,
      status: 'SUCCESS',
      meta: { path: ['cacheInvalidated'], not: true }
    },
    orderBy: { createdAt: 'desc' }
  });
  if (!r) return null;
  // 추가: 결과 파일 TTL 검증 (signed URL 만료 등)
  return r;
}
```

---

## 5. Finalize / Immutable (ER-160 ~ ER-169)

### ER-160. 마감일 후 결과 immutable (MUST)

`payroll.period_closed` / `inventory.month_closed` 이벤트 수신 시:
- 해당 기간을 다루는 모든 SUCCESS run 의 `finalized_at = now()`, `is_immutable = true`
- 이후 재실행 / 무효화 X — 회계 / 세무 의무로 결과 immutable

```typescript
async function handlePeriodClosed(event) {
  await db.reportRun.updateMany({
    where: {
      organizationId: event.orgId,
      status: 'SUCCESS',
      definition: { sourceModules: { has: event.module }},
      // parameters 가 해당 기간을 참조
    },
    data: { isImmutable: true, finalizedAt: new Date() }
  });
}
```

### ER-165. immutable run 의 다운로드 (MUST)

- 결과 파일 storage 의 영구 보관 (만료 X)
- signed URL 은 매번 새로 발급
- audit 강화 — 누가 언제 다운로드 (감사 추적)

---

## 6. PII 분리 결과 (ER-170 ~ ER-179)

### ER-170. 권한별 결과 파일 (MUST)

생성 시 마스킹 / 풀 두 버전 모두 저장:
```typescript
async function generateAndStoreResults(run, def, rawData) {
  const masked = applyMasking(rawData, def.piiColumns, 'L3');
  const full = rawData;  // 풀

  const maskedUrl = await uploadToStorage(masked, run.id, '_masked');
  const fullUrl = await uploadToStorage(full, run.id, '_full');

  await db.reportRun.update({
    where: { id: run.id },
    data: {
      resultMaskedUrl: maskedUrl,
      resultFullUrl: fullUrl,
      resultFileUrl: maskedUrl,    // 기본
      resultRowCount: rawData.length
    }
  });
}
```

### ER-175. 다운로드 시점 권한 검증 (MUST)

```typescript
async function downloadReport(runId, actor) {
  const run = await loadRun(runId);
  const def = await loadDefinition(run.definitionId);

  // 권한 재검증 (실행 시 O, 다운로드 시 변경 가능)
  await checkReportPermission(def, actor);

  // 권한 등급에 따라 URL 선택
  const actorMaxLevel = await getMaxLevel(actor, def.sourceModules);
  const url = compareLevel(actorMaxLevel, 'L4') >= 0
    ? run.resultFullUrl
    : run.resultMaskedUrl;
  return generateSignedUrl(url, { ttl: 900 });   // 15분 TTL
}
```

---

## 7. 권한 / 감사 (ER-180 ~ ER-199)

### ER-180. 감사 (모듈 통합)

| action | 시점 |
|---|---|
| `report.run.started` | 실행 시작 (definition + parameters) |
| `report.run.succeeded` | 결과 생성 완료 |
| `report.run.failed` | 실패 (에러 메시지) |
| `report.run.cancelled` | 취소 |
| `report.run.cache_hit` | 캐시 hit (재실행 회피) |
| `report.run.cache_invalidated` | 캐시 무효화 |
| `report.run.finalized` | 마감으로 immutable |
| `report.run.downloaded` | 다운로드 (actor + format + masked/full) |
| `report.run.permission_denied` | 권한 부족 거부 |

### ER-185. 권한 (요약)

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| 본인 / 팀 보고서 실행 | ❌ | ✅ | ✅ | ✅ |
| 조직 전체 보고서 실행 | ❌ | ⚠️ (정의별) | ✅ | ✅ |
| 풀 PII 결과 다운로드 | ❌ | ❌ | ✅ | ✅ |
| immutable run 강제 재생성 | ❌ | ❌ | ❌ | ✅ + audit |

---

## 8. 참조

- 정의: `report_definition.md` (ER-001~099)
- 스케줄: `scheduling.md` (ER-200~)
- 배포: `distribution.md` (ER-300~)
- 보존: `retention.md` (ER-400~)
- 게이트: `feature_flags.md` (`report.cache_aggressive`)
- 스키마: `../schemas/tables/report_runs.sql`
