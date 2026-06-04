# 보고서 배포 (Distribution)

> **ID 범위**: ER-300 ~ ER-399
> **주제**: 보고서 결과 배포 (이메일 / 다운로드 / API / Slack)
> **상위**: `INDEX.md`
> **게이트**: `report.email_distribution`, `report.api_export`

---

## TL;DR

- **3 채널**: download (UI signed URL), email (자동 발송), API (외부 시스템 호출).
- **수신자 검증 (MUST)** — 메일 / API 키는 화이트리스트. 외부 검증 없이 발송 X.
- **PII 마스킹 우선 (MUST)** — 외부 발송은 기본 마스킹, 풀 PII 는 별도 권한 + 외부 수신자 검증.
- **이메일 첨부 한도** — 10MB 초과 시 본문에 signed URL 만 (3일 TTL). 첨부 X.
- **재발송 (MUST)** — 같은 run + 같은 채널 재발송 가능 (audit). 새 url / 새 token.
- **실패 / 반송 (MUST)** — bounce / 미수신 처리 + 운영자 알림.
- **API 키 / Webhook URL 보호 (MUST)** — 시크릿 store. UI 노출 X (마스킹 표시).

핵심 ID: ER-310 (모델) / ER-320 (download) / ER-330 (email) / ER-340 (API) / ER-360 (수신자 검증) / ER-380 (재발송)

---

## 1. 모델 (ER-300 ~ ER-319)

### ER-310. report_distributions 테이블 (MUST)

```sql
CREATE TABLE report_distributions (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  run_id          UUID NOT NULL,
  channel         VARCHAR(20) NOT NULL,         -- DOWNLOAD / EMAIL / API / SLACK
  recipients      JSONB NOT NULL,                -- [{ kind, value, masked }]
  pii_level       VARCHAR(10) NOT NULL,          -- MASKED / FULL
  status          VARCHAR(20) NOT NULL,          -- PENDING / SENT / FAILED / BOUNCED
  error_message   TEXT,
  sent_at         TIMESTAMPTZ,
  delivered_at    TIMESTAMPTZ,                   -- bounce / open 등 추적
  meta            JSONB,
  created_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- 중복 방지 (재발송은 별도 row)
  UNIQUE (run_id, channel, recipients_hash)      -- recipients_hash = SHA-256 of recipients
);
```

### ER-315. 채널별 recipients 형식 (MUST)

| 채널 | recipients |
|---|---|
| DOWNLOAD | `[{ kind: 'user', user_id: '...' }]` |
| EMAIL | `[{ kind: 'email', value: 'a@b.com', masked: 'a***@b.com' }]` |
| API | `[{ kind: 'api_endpoint', endpoint_id: '...', masked: 'https://***/hooks' }]` |
| SLACK | `[{ kind: 'slack_channel', channel: '#reports' }]` |

---

## 2. Download 채널 (ER-320 ~ ER-329)

### ER-320. signed URL 다운로드 (MUST)

UI 다운로드 = signed URL (외부 storage):
```typescript
async function downloadReportRun(runId, actor) {
  const run = await loadRun(runId);
  const def = await loadDefinition(run.definitionId);
  await checkReportPermission(def, actor);

  // 권한 등급 → URL 결정 (마스킹 / 풀)
  const piiLevel = await resolvePiiLevel(actor, def);
  const url = piiLevel === 'FULL' ? run.resultFullUrl : run.resultMaskedUrl;

  const signed = await generateSignedUrl(url, { ttl: 900 });  // 15분
  await db.reportDistribution.create({
    data: {
      organizationId: actor.orgId, runId, channel: 'DOWNLOAD',
      recipients: [{ kind: 'user', userId: actor.id }],
      piiLevel, status: 'SENT', sentAt: new Date(), createdBy: actor.id
    }
  });
  return signed;
}
```

### ER-325. signed URL TTL (MUST)

- 일반 다운로드: 15 분
- 외부 link share (이메일 첨부 대체): 3 일
- immutable run (감사 / 결산): 매번 새 발급, 영구 보관 보장

---

## 3. Email 채널 (ER-330 ~ ER-339) — 토글 ON 시 MUST

### ER-330. 이메일 발송 정책 (MUST)

토글 `report.email_distribution = ON` 필요. 외부 발송이라 보수적:
- 수신자 = 사전 등록된 이메일 화이트리스트
- 본문 / 제목 / 첨부 = 보고서 정의의 메타에서 결정 (자유 입력 X)
- 첨부 < 10MB 만 — 초과 시 signed URL (3일 TTL)
- DKIM / SPF 정상 발송 도메인만

### ER-335. 발송 패턴 (MUST)

```typescript
async function distributeByEmail(run, recipients, piiLevel, actor) {
  const def = await loadDefinition(run.definitionId);
  await checkPermissionForExternalDistribution(def, actor, piiLevel);

  // 수신자 화이트리스트 검증
  for (const r of recipients) {
    const ok = await isWhitelistedEmail(actor.orgId, r.value);
    if (!ok) throw new RecipientNotWhitelistedError(r.value);
  }

  const fileUrl = piiLevel === 'FULL' ? run.resultFullUrl : run.resultMaskedUrl;
  const fileSize = run.resultFileSize;

  const subject = `[${def.name}] ${formatPeriod(run.parameters)}`;
  const body = renderEmailTemplate(def.code, run);

  const dist = await db.reportDistribution.create({
    data: {
      organizationId: actor.orgId, runId: run.id, channel: 'EMAIL',
      recipients: recipients.map(r => ({ ...r, masked: maskEmail(r.value) })),
      piiLevel, status: 'PENDING', createdBy: actor.id
    }
  });

  if (fileSize <= 10 * 1024 * 1024) {
    await sendEmailWithAttachment(recipients, subject, body, fileUrl);
  } else {
    const link = await generateSignedUrl(fileUrl, { ttl: 3 * 24 * 3600 });
    await sendEmailWithLink(recipients, subject, body, link);
  }

  await db.reportDistribution.update({
    where: { id: dist.id },
    data: { status: 'SENT', sentAt: new Date() }
  });
}
```

### ER-338. 반송 / bounce 처리 (MUST)

이메일 ESP webhook (SendGrid / SES):
- bounce → status = BOUNCED + 알림
- 같은 수신자 3 회 bounce → 화이트리스트에서 자동 제거
- 운영자 알림 (반복 반송 = 잘못된 주소)

---

## 4. API 채널 (ER-340 ~ ER-349) — 토글 ON 시 MUST

### ER-340. API webhook (MUST)

토글 `report.api_export = ON` 필요. 외부 시스템에 결과 PUSH:
- POST 요청 (JSON body) — 결과 데이터 또는 signed URL
- HMAC 서명 (수신자 검증용)
- 멱등 키 (run_id) 헤더

```typescript
async function distributeByApi(run, endpoint, piiLevel) {
  const payload = {
    runId: run.id,
    reportCode: run.definition.code,
    parameters: run.parameters,
    resultUrl: piiLevel === 'FULL' ? run.resultFullUrl : run.resultMaskedUrl,
    generatedAt: run.finishedAt
  };
  const signature = hmacSha256(JSON.stringify(payload), endpoint.secret);

  const res = await fetch(endpoint.url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Report-Run-Id': run.id,
      'X-Signature': signature
    },
    body: JSON.stringify(payload)
  });
  // 응답 검증 → SENT / FAILED
}
```

### ER-345. API 키 / 시크릿 (MUST)

`report_api_endpoints` 테이블 (Phase 1+):
```sql
CREATE TABLE report_api_endpoints (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  name            VARCHAR(200) NOT NULL,
  url             TEXT NOT NULL,
  secret_ref      VARCHAR(100) NOT NULL,         -- 시크릿 store reference
  is_active       BOOLEAN NOT NULL DEFAULT TRUE
);
```

UI 에는 url 마스킹 표시 (`https://***`). 시크릿은 표시 X.

---

## 5. Slack 채널 (ER-350 ~ ER-359) — 옵션, Phase 1+

### ER-350. Slack 발송 (Phase 1+)

`report.slack_distribution` 토글 (Phase 1+ 추가):
- Slack incoming webhook URL
- 채널별 화이트리스트
- 발송 = 요약 + signed URL (마스킹 결과만, 풀 PII 외부 채널 금지)

---

## 6. 수신자 검증 (ER-360 ~ ER-369) — MUST

### ER-360. 화이트리스트 (MUST)

`report_recipients_whitelist` 테이블 (Phase 1+):
```sql
CREATE TABLE report_recipients_whitelist (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  channel         VARCHAR(20) NOT NULL,
  recipient_value VARCHAR(255) NOT NULL,         -- email / endpoint_url / slack_channel
  added_by        UUID NOT NULL,
  added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (organization_id, channel, recipient_value)
);
```

신규 수신자는 L4 권한자가 추가. 추가 시 audit + (옵션) 검증 이메일 (소유 확인).

### ER-365. 풀 PII 외부 발송 (MUST)

```typescript
async function checkPermissionForExternalDistribution(def, actor, piiLevel) {
  if (piiLevel === 'FULL') {
    if (compareLevel(actor.maxLevel, 'L4') < 0) {
      throw new InsufficientPermissionError('풀 PII 외부 발송은 L4+ 권한 필요');
    }
  }
}
```

---

## 7. 재발송 / 회수 (ER-380 ~ ER-389)

### ER-380. 재발송 (MUST)

같은 run + 채널 + 수신자 재발송 = 새 distribution row + 새 signed URL:
- 기존 URL invalidate (옵션)
- audit 강화 (resend reason)

### ER-385. 회수 (MUST, 한정)

이메일은 회수 불가 (이미 발송). signed URL revoke 만 가능:
- url 기반 분배 → revoke 가능
- 첨부 발송 → 수신자 측에 도달했으면 회수 X

---

## 8. 권한 / 감사 (ER-390 ~ ER-399)

### ER-390. 권한

| 작업 | L3 | L4 | Super |
|---|---|---|---|
| Download (마스킹) | ✅ | ✅ | ✅ |
| Download (풀 PII) | ❌ | ✅ | ✅ |
| Email 수동 발송 (마스킹) | ✅ | ✅ | ✅ |
| Email 수동 발송 (풀 PII) | ❌ | ✅ | ✅ |
| 화이트리스트 추가 / 제거 | ❌ | ✅ | ✅ |
| API 엔드포인트 등록 | ❌ | ❌ | ✅ |
| 자동 발송 schedule | ✅ (마스킹만) | ✅ | ✅ |

### ER-395. 감사

| action | 시점 |
|---|---|
| `report.distribution.queued` | 발송 대기 |
| `report.distribution.sent` | 발송 완료 |
| `report.distribution.failed` | 발송 실패 |
| `report.distribution.bounced` | 반송 |
| `report.distribution.full_pii_distributed` | 풀 PII 외부 발송 (강화 audit) |
| `report.recipient.whitelisted` | 화이트리스트 추가 |
| `report.recipient.removed` | 화이트리스트 제거 |
| `report.distribution.resent` | 재발송 |

---

## 9. 참조

- 게이트: `feature_flags.md` (`report.email_distribution`, `report.api_export`)
- 결과 모델: `report_generation.md` (ER-110)
- PII 마스킹: `report_definition.md` (ER-090)
- 보존: `retention.md` (ER-450)
- 스키마: `../schemas/tables/report_distributions.sql`
