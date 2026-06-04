# 보관 / 감사 (Retention & Audit)

> **ID 범위**: ER-400 ~ ER-499
> **주제**: 결과 / 정의 / 스케줄 / 배포 이력의 보존 / 자동 삭제 / 감사
> **상위**: `INDEX.md`

---

## TL;DR

- **결산 보고서 보존 기간 = 5~10년** (회계 / 세무 의무).
- **일반 보고서 = 1년 기본** — 정의 / 조직 정책으로 조정.
- **immutable run = 영구 보관** — 회계 / 결산 / 마감 보고서. 삭제 X.
- **PII 만 시간 차 마스킹 가능** — 결과 자체는 보관, PII 컬럼만 시간 후 마스킹 / 삭제.
- **자동 삭제 = 배치 cron** — 매일 새벽. 보존 기간 초과 결과 / 만료된 url / inactive 스케줄.
- **감사 로그 = 별도 보존 정책** — 모든 audit 은 최소 5년, 일부 (PII 풀 노출) 는 7년.
- **삭제 시점 audit (MUST)** — 자동 삭제도 audit 기록 (행적).

핵심 ID: ER-410 (결산 보존) / ER-420 (일반 보존) / ER-430 (PII 시차 마스킹) / ER-440 (자동 삭제) / ER-460 (감사 보존)

---

## 1. 보존 기간 매트릭스 (ER-400 ~ ER-419)

### ER-410. 법정 보존 기간 (KR, MUST)

| 보고서 종류 | 근거법 | 기간 |
|---|---|---|
| 급여대장 / 임금명세서 | 근로기준법 §42 | **3년** |
| 4대보험 신고서 | 국민연금법 / 건강보험법 / 고용보험법 | **3년** |
| 원천세 신고 / 지급명세서 | 소득세법 §164 | **5년** |
| 부가가치세 자료 / 세금계산서 | 부가가치세법 §32 | **5년** |
| 거래 기록 (전자상거래) | 전자상거래법 §6 ③ | **5년** |
| 회계장부 / 재무제표 | 상법 §33 (10년) / K-IFRS | **10년** |
| 일반 영업 자료 | 상법 §33 ② | **10년** |

### ER-415. 정의별 보존 정책 (MUST)

`report_definitions.retention_days`:
```sql
ALTER TABLE report_definitions
  ADD COLUMN retention_days INTEGER NOT NULL DEFAULT 365,
  ADD COLUMN pii_retention_days INTEGER;       -- NULL = 동일
```

KR 표준 보고서 기본값 (시드):
- `KR_PAYROLL_*`: 1825 일 (5년) — 원천세 / 4대보험 통합 기준
- `KR_INVENTORY_VALUATION`: 3650 일 (10년) — 회계장부
- `KR_FINANCIAL_CLOSING_MONTHLY`: 3650 일 (10년)
- `KR_LOGISTICS_*`: 1825 일 (5년) — 전자상거래 거래기록

### ER-418. immutable run = 영구 (MUST)

`is_immutable=true` (ER-160) 인 run 은 retention 정책 무시 — 영구 보관:
- 결산 / 마감 보고서
- 외부 신고 자료 (4대보험 / 원천세)

---

## 2. 결과 파일 보관 (ER-420 ~ ER-429)

### ER-420. 외부 storage 정책 (MUST)

- 활성 (1 년 내): hot tier (S3 Standard)
- 보관 (1~5년): cold tier (S3 Glacier / IA)
- 영구: cold + lifecycle 정책 + cross-region replication

### ER-425. signed URL 발급 (MUST)

DB 의 `result_file_url` 은 path / key 만 저장. 다운로드 시 매번 새 signed URL 발급:
```typescript
async function getDownloadUrl(runId, actor) {
  const run = await loadRun(runId);
  // ... 권한 검증
  return await storage.getSignedUrl(run.resultFileKey, { ttl: 900 });
}
```

영구 키는 매번 새 발급 가능 (만료된 URL 도 재발급).

---

## 3. PII 시차 마스킹 (ER-430 ~ ER-439)

### ER-430. 동기 / 비동기 처리 (MUST)

원리: 결과 row 자체는 보존 (감사 / 회계 의무), PII 컬럼만 일정 시간 후 마스킹.

```sql
ALTER TABLE report_definitions
  ADD COLUMN pii_mask_after_days INTEGER;     -- 결과 생성 후 N 일 뒤 PII 마스킹
```

기본 = NULL (즉시 마스킹 / 풀 결과 별도 보관 ER-170).

### ER-435. 처리 워커 (MUST)

매일 cron:
```typescript
async function maskPiiInOldRuns() {
  const runs = await db.reportRun.findMany({
    where: {
      finishedAt: { lt: subDays(new Date(), thresholdDays) },
      meta: { path: ['piiMasked'], not: true },
      isImmutable: false  // immutable 은 풀 보관
    }
  });
  for (const r of runs) {
    await maskPiiInResult(r);
    // result_full_url 삭제 / result_masked_url 만 유지
  }
}
```

immutable 은 풀 보관 (회계 / 세무 감사 대비).

---

## 4. 자동 삭제 (ER-440 ~ ER-449) — MUST

### ER-440. 보존 초과 result 삭제 (MUST)

매일 cron:
```typescript
async function purgeExpiredResults() {
  const definitions = await db.reportDefinition.findMany();
  for (const def of definitions) {
    const cutoff = subDays(new Date(), def.retentionDays);
    const candidates = await db.reportRun.findMany({
      where: {
        definitionId: def.id,
        finishedAt: { lt: cutoff },
        isImmutable: false,
        meta: { path: ['purged'], not: true }
      }
    });
    for (const r of candidates) {
      await purgeRun(r);   // storage 파일 삭제 + meta 갱신
    }
  }
}

async function purgeRun(r) {
  await db.$transaction(async (tx) => {
    if (r.resultFileKey) await storage.delete(r.resultFileKey);
    if (r.resultFullKey) await storage.delete(r.resultFullKey);
    if (r.resultMaskedKey) await storage.delete(r.resultMaskedKey);
    await tx.reportRun.update({
      where: { id: r.id },
      data: { meta: { purged: true, purgedAt: new Date() }, resultFileUrl: null, resultFullUrl: null, resultMaskedUrl: null }
    });
    await writeAudit({ action: 'report.run.purged', target: r.id, metadata: { reason: 'retention' }});
  });
}
```

> row 자체는 보존 (audit), 결과 파일과 url 만 삭제.

### ER-445. inactive 스케줄 정리 (옵션)

`is_active=false` 이고 `updated_at < (now - 1년)` 스케줄:
- 자동 archive (별도 테이블 또는 soft delete)
- 또는 운영자 알림 후 수동 정리

### ER-448. 화이트리스트 정리 (옵션)

`report_recipients_whitelist` 의 `last_used_at < (now - 6개월)` 인 항목:
- L4 알림 → 수동 비활성화 결정

---

## 5. 결과 / 정의 / 스케줄 vs audit log 보존

### ER-450. 분리 정책 (MUST)

| 데이터 | 기본 보존 | 비고 |
|---|---|---|
| `report_runs` row (메타) | 3년 ~ 영구 (정의 retention 따라) | row 자체 |
| `report_runs.result_*_url` (파일) | 정의 retention | 만료 시 file 삭제, row 보존 |
| `report_distributions` row | 정의 retention | 발송 이력 |
| `report_schedules` row | 영구 (active 시) | inactive 후 1년 정리 가능 |
| `report_definitions` row | 영구 | 변경은 새 버전 (ER-015) |
| audit log (`report.*`) | 5년 (PII 노출은 7년) | 별도 audit 정책 |

---

## 6. Audit 보존 (ER-460 ~ ER-469) — MUST

### ER-460. audit 별도 정책 (MUST)

audit log 는 보고서 retention 과 별개:
- 모든 `report.*` 액션: 최소 5년
- 풀 PII 노출 (`report.distribution.full_pii_distributed`, `report.run.downloaded` with full): 7년
- Super 강제 액션: 영구

### ER-465. audit 컬럼 (MUST)

- actor_id (NOT NULL)
- target (run_id / definition_id / schedule_id)
- action (네임스페이스 `report.*`)
- timestamp (UTC)
- metadata (JSONB) — 권한 / PII 레벨 / 추가 정보
- IP / user_agent (해시)

### ER-468. audit 변경 금지 (MUST)

audit log 는 append-only. UPDATE / DELETE 차단:
```sql
REVOKE UPDATE, DELETE ON audit_logs FROM application_user;
```

또는 별도 시스템 (CloudWatch / Datadog / 자체 ledger).

---

## 7. GDPR / 한국 개인정보보호법 (ER-470 ~ ER-479)

### ER-470. 데이터 주체 요청 (MUST, Phase 1+)

데이터 주체 (사용자 / 수령자) 가 자신의 데이터 삭제 요청 시:
- 보고서에 포함된 PII 식별
- 해당 row 삭제 / 마스킹
- 단, 법정 보존 기간 내는 거부 가능 (회계 / 세무 의무)
- 처리 결과 audit + 데이터 주체에 통보

### ER-475. 처리 시한 (MUST, KR)

개인정보보호법 §35 — 30일 이내 처리. 연장 시 사유 통보 (60일까지).

> Phase 0 는 룰만, 실 구현은 Phase 1+. 운영자 수동 처리 가능.

---

## 8. 권한 / 감사 (ER-480 ~ ER-499)

### ER-480. 권한

| 작업 | L4 | Super |
|---|---|---|
| 보존 정책 변경 (정의별 retention_days) | ✅ | ✅ |
| 수동 결과 삭제 (immutable 외) | ✅ + audit | ✅ |
| immutable run 강제 삭제 | ❌ | ✅ + 강화 audit + 사유 |
| audit log 조회 | ✅ | ✅ |
| audit log 익스포트 | ✅ + audit | ✅ |
| 데이터 주체 요청 처리 | ✅ + audit | ✅ |

### ER-490. 감사 (자동 작업)

| action | 시점 |
|---|---|
| `report.run.purged` | 자동 / 수동 결과 파일 삭제 |
| `report.run.pii_masked` | PII 시차 마스킹 적용 |
| `report.schedule.archived` | 스케줄 archive |
| `report.retention.policy_changed` | 보존 정책 변경 |
| `report.subject_request.received` | 데이터 주체 요청 수신 |
| `report.subject_request.processed` | 요청 처리 완료 |

---

## 9. 참조

- 결과 모델: `report_generation.md` (ER-110, ER-160)
- 정의: `report_definition.md` (ER-010)
- 배포: `distribution.md`
- 게이트: `feature_flags.md`
- 스키마: `../schemas/INDEX.md`
- 한국 법정 보존 근거: 근로기준법 §42, 소득세법 §164, 부가가치세법 §32, 상법 §33, 전자상거래법 §6
