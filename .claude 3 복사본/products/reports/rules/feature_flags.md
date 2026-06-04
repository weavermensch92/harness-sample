# 모듈 기능 토글 (Feature Flags)

> **ID 범위**: ER-900 ~ ER-999
> **주제**: 조직 / 시설 레벨 reports 하위 기능 토글
> **상위**: `INDEX.md`

> 메커니즘은 `payroll/rules/feature_flags.md` (EP-900) / `inventory/rules/feature_flags.md` (EI-900) / `logistics/rules/feature_flags.md` (EL-900) 와 동일. reports 카탈로그 / 의존성만 다룸.

---

## TL;DR

- **저장**: `report_feature_flags` (구조 동일, 모듈만 분리)
- **변경 권한**: L4 (조직) / Super (전체)
- **기본값**: 외부 발송 / 외부 노출 토글은 보수적 OFF. 내부 (다운로드 / 스케줄 / 캐시) 는 ON.
- **의존성** — `email_distribution` / `api_export` 외부 발송은 별도 안전 검증.

핵심 ID: ER-910 (스키마) / ER-920 (런타임) / ER-940 (의존성)

---

## 1. 토글 카탈로그 (ER-900 ~ ER-909)

### ER-900. 정의된 토글 (MUST 동기 유지)

| feature_key | 기본값 | 룰 | 의존 |
|---|---|---|---|
| `report.scheduled_runs` | ON | `scheduling.md` | — |
| `report.email_distribution` | OFF | `distribution.md` (ER-330) | — |
| `report.api_export` | OFF | `distribution.md` (ER-340) | — |
| `report.csv_export` | ON | (export format) | — |
| `report.xlsx_export` | ON | (export format) | — |
| `report.pdf_export` | OFF | (Phase 1+) | — |
| `report.kr_legal_pack` | OFF | `report_definition.md` (ER-040~) | — |
| `report.cache_aggressive` | ON | `report_generation.md` (ER-150) | — |
| `report.realtime_dashboard` | OFF | (Phase 2+) | — |
| `report.slack_distribution` | OFF | `distribution.md` (ER-350) | (Phase 1+) |
| `report.subject_request_handling` | OFF | `retention.md` (ER-470) | (Phase 1+) |

### ER-901. 명명 규약 (MUST)

`report.{subkey}` — payroll / inventory / logistics 와 동일.

---

## 2. 스키마 / 런타임 (ER-910 ~ ER-929)

### ER-910. report_feature_flags (MUST)

다른 모듈과 구조 동일:
```sql
CREATE TABLE report_feature_flags (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  scope_type      VARCHAR(20) NOT NULL,
  scope_id        UUID NOT NULL,
  feature_key     VARCHAR(100) NOT NULL,
  enabled         BOOLEAN NOT NULL,
  changed_by      UUID NOT NULL,
  changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason          TEXT,
  notes           JSONB,
  UNIQUE (organization_id, scope_type, scope_id, feature_key)
);
```

### ER-920. requireFeature (MUST)

기능 진입점 명시 체크 — 다른 모듈과 동일:
```typescript
async function distributeByEmail(run, recipients, actor) {
  await requireFeature(actor.organizationId, 'report.email_distribution');
  // ...
}
```

---

## 3. 의존성 (ER-940 ~ ER-949)

### ER-940. 의존성 표

reports 의 의존은 기본적으로 적음. 특이 케이스:
- `report.kr_legal_pack` ON 시 → 시드 데이터 자동 INSERT (KR_PAYROLL_INSURANCE 등 BUILTIN 정의)

### ER-945. 외부 발송 안전 검증 (MUST)

`email_distribution` / `api_export` / `slack_distribution` 켤 때 추가 검증:
- 화이트리스트 등록 여부 (ER-360)
- DKIM / SPF 설정 (이메일)
- API endpoint HTTPS 검증

```typescript
async function validateExternalDistributionEnable(scope, feature) {
  if (feature === 'report.email_distribution') {
    const senders = await db.emailSender.findMany({ where: { organizationId: scope.orgId, dkimVerified: true }});
    if (senders.length === 0) {
      throw new EmailSenderNotConfiguredError('DKIM 검증된 발송자 등록 필요');
    }
  }
  if (feature === 'report.api_export') {
    const endpoints = await db.reportApiEndpoint.findMany({ where: { organizationId: scope.orgId, isActive: true }});
    if (endpoints.length === 0) {
      throw new ApiEndpointNotConfiguredError('활성 API 엔드포인트 등록 필요');
    }
  }
}
```

---

## 4. 권한 / 감사 (ER-950 ~ ER-999)

### ER-950. 권한

| 작업 | L3 | L4 | Super |
|---|---|---|---|
| 토글 조회 | ✅ | ✅ | ✅ |
| ORGANIZATION / FACILITY 토글 변경 | ❌ | ✅ | ✅ |
| 외부 발송 토글 (email/api/slack) 변경 | ❌ | ⚠️ (검증 후) | ✅ |
| `kr_legal_pack` 변경 (시드) | ❌ | ❌ | ✅ |

### ER-960. 감사

| action | 시점 |
|---|---|
| `report.feature_flag.changed` | 토글 변경 |
| `report.feature_flag.external_distribution_enabled` | 외부 발송 활성화 (강화 audit) |
| `report.feature_flag.kr_legal_pack_seeded` | 법정 보고서 시드 |

---

## 5. 참조

- 동일 메커니즘: `payroll/rules/feature_flags.md`, `inventory/rules/feature_flags.md`, `logistics/rules/feature_flags.md`
- 룰 카탈로그: `INDEX.md` § 7
- 스키마: `../schemas/tables/report_feature_flags.sql`
