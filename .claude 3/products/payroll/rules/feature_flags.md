# 모듈 기능 토글 (Feature Flags)

> **ID 범위**: EP-900 ~ EP-999
> **주제**: 조직 / 시설 레벨에서 payroll 하위 기능을 켜고 끌 수 있는 시스템
> **상위**: `INDEX.md`

---

## TL;DR

- **목적**: 조직 / 시설마다 적용되는 노동 형태 / 회계 정책이 달라서 payroll 의 모든 기능을 일률 적용하면 오히려 혼란. 일용직 / 업무별 단가 같은 기능은 **사업장 정책으로 토글**.
- **저장 위치**: `payroll_feature_flags` 테이블. 조직 / 시설 / 팀 스코프 + 기능 키 + enabled.
- **변경 권한**: L4 (조직 단위) / Super (전체). L3 이하 토글 불가.
- **기본값**: 모든 토글 OFF (보수적). 신규 도입 시 명시적으로 ON.
- **변경 이력**: 모든 토글 변경은 audit + 변경자 / 시점 / 사유 기록.
- **의존성**: 일부 토글은 다른 토글 ON 을 전제 (예: piecework → work_log_piecework_source).
- **런타임 체크**: 모든 기능 진입 시 `requireFeature(orgId, 'payroll.day_laborer')` 호출. 미활성이면 거부.

핵심 ID: EP-910 (스키마) / EP-920 (런타임 체크) / EP-930 (변경) / EP-940 (의존성)

---

## 1. 토글 카탈로그 (EP-900 ~ EP-909)

### EP-900. 현재 정의된 토글 (MUST 동기 유지)

| feature_key | 영역 | 기본값 | 룰 연결 | 의존 |
|---|---|---|---|---|
| `payroll.day_laborer` | 일용근로자 처리 (특례 세율 / 즉시 지급 / 간이명세서) | OFF | `day_laborer.md` (EP-700~) | — |
| `payroll.piecework` | 업무별 단가 (PIECEWORK scheme) | OFF | `piecework.md` (EP-800~) | `payroll.work_log_piecework_source` |
| `payroll.work_log_piecework_source` | work_logs.source_type 에 PIECEWORK 허용 | OFF | EP-101 보강 | — |
| `payroll.weekly_holiday_strict` | 주휴수당 자동 검증 강제 | ON | EP-335 | — |
| `payroll.under5_employee_relief` | 5인 미만 사업장 가산수당 면제 | OFF | EP-321 | — |
| `payroll.firmbanking_provider` | 펌뱅킹 어댑터 사용 | OFF | EP-540 | — |
| `payroll.openbanking_provider` | 오픈뱅킹 어댑터 사용 | OFF | EP-540 | — |
| `payroll.payslip_email_delivery` | 명세서 이메일 자동 발송 | ON | EP-461 | — |
| `payroll.payslip_acknowledgment_required` | 명세서 수신 확인 강제 | OFF | EP-462 | `payroll.payslip_email_delivery` |
| `payroll.minimum_wage_validation` | 최저임금 시급 환산 검증 | ON | EP-240 | — |
| `payroll.deduction_rate_yearly_alert` | 요율 미입력 자동 알림 | ON | EP-362 | — |
| `payroll.income_tax_table_2026` | 2026 간이세액표 사용 | ON | EP-380 | — |
| `payroll.clawback_quarter_limit` | 환수 1/4 한도 강제 (KR §43) | ON | EP-561 | — |

> 새 토글 추가 / 제거는 마이그레이션 + 룰 동기 수정 필요.

### EP-901. 명명 규약 (MUST)

`{module}.{feature_subkey}` — 점(.) 으로 모듈 / 하위 기능 구분.

```
✅ payroll.day_laborer
✅ inventory.barcode_scan
❌ day_laborer (모듈 prefix 없음)
❌ payroll-day-laborer (구분자 -)
❌ payroll.dayLaborer (camelCase)
```

### EP-902. 토글 vs 설정 구분 (MUST)

- **토글 (이 룰의 대상)**: ON / OFF 만. 기능 자체의 활성 여부.
- **설정 (별도)**: 값이 있는 환경 변수 / 정책. (예: `payday_pattern`, `standard_monthly_hours`, `bank_provider`)

같은 영역에 토글과 설정이 동시에 있을 수 있음:
- 토글: `payroll.firmbanking_provider = ON`
- 설정: `firmbanking.bank_code = '004'`

토글이 OFF 면 설정 무시. 토글이 ON 인데 설정 누락이면 런타임 에러.

---

## 2. 스키마 (EP-910 ~ EP-919)

### EP-910. payroll_feature_flags 모델 (MUST)

```sql
CREATE TABLE payroll_feature_flags (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  scope_type      VARCHAR(20) NOT NULL,        -- 'ORGANIZATION' / 'FACILITY' / 'TEAM'
  scope_id        UUID NOT NULL,                -- ORGANIZATION 이면 organization_id 와 동일
  feature_key     VARCHAR(100) NOT NULL,        -- 'payroll.day_laborer' 등
  enabled         BOOLEAN NOT NULL,
  changed_by      UUID NOT NULL,
  changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason          TEXT,                          -- 변경 사유 (운영자 입력 권고)
  notes           JSONB,                         -- 추가 메타 (예: 의존 토글 함께 켜진 정보)
  UNIQUE (organization_id, scope_type, scope_id, feature_key)
);
```

- 같은 (org, scope_type, scope_id, feature_key) 는 1 row — 변경 시 UPDATE
- 변경 이력은 별도 `payroll_feature_flag_history` 테이블 (Phase 1+) 또는 audit_logs 활용

### EP-911. 스코프 우선순위 (MUST)

조회 시 더 좁은 스코프 우선:

```
TEAM > FACILITY > ORGANIZATION > 기본값
```

```typescript
async function isFeatureEnabled(
  orgId: string, feature: string,
  facilityId?: string, teamId?: string
): Promise<boolean> {
  // 1. TEAM 레벨
  if (teamId) {
    const t = await db.payrollFeatureFlag.findFirst({
      where: { organizationId: orgId, scopeType: 'TEAM', scopeId: teamId, featureKey: feature }
    });
    if (t) return t.enabled;
  }
  // 2. FACILITY 레벨
  if (facilityId) {
    const f = await db.payrollFeatureFlag.findFirst({
      where: { organizationId: orgId, scopeType: 'FACILITY', scopeId: facilityId, featureKey: feature }
    });
    if (f) return f.enabled;
  }
  // 3. ORGANIZATION 레벨
  const o = await db.payrollFeatureFlag.findFirst({
    where: { organizationId: orgId, scopeType: 'ORGANIZATION', scopeId: orgId, featureKey: feature }
  });
  if (o) return o.enabled;
  // 4. 기본값 (EP-900 카탈로그)
  return DEFAULT_FLAGS[feature] ?? false;
}
```

### EP-915. 캐시 (SHOULD)

매 요청마다 DB 조회는 부담. 메모리 캐시 + 5분 TTL 또는 변경 시 invalidate (이벤트 기반).

```typescript
const cache = new TTLCache<string, boolean>({ ttl: 300_000 });
// 변경 시 cache.delete(`${orgId}:${feature}`) — 모든 팀/시설 키도 invalidate
```

캐시 invalidation 은 EP-930 변경 트랜잭션과 같이.

---

## 3. 런타임 체크 (EP-920 ~ EP-929)

### EP-920. requireFeature 헬퍼 (MUST)

기능 진입점에서 명시적 체크:

```typescript
async function requireFeature(
  orgId: string, feature: string,
  ctx?: { facilityId?: string; teamId?: string }
): Promise<void> {
  const enabled = await isFeatureEnabled(orgId, feature, ctx?.facilityId, ctx?.teamId);
  if (!enabled) {
    throw new FeatureNotEnabledError(
      `${feature} 기능이 비활성 상태입니다. 관리자에게 문의하세요.`
    );
  }
}

// 사용:
async function createDayLaborerWorkLog(req: Req, actor: User) {
  await requireFeature(actor.organizationId, 'payroll.day_laborer', {
    facilityId: req.facilityId, teamId: req.teamId
  });
  // ... 본 로직
}
```

### EP-921. 비활성 상태에서의 데이터 (MUST)

토글 OFF 가 되면:

- **읽기는 허용** (이미 생성된 데이터 조회는 가능). 사용자가 "이전에 만든 일용직 데이터" 를 못 볼 수 없음.
- **새 생성 / 수정은 차단**. 새로 일용직 등록 / piecework work_log 생성 불가.
- **자동 작업 (배치) 은 skip**. 비활성 시설의 일용직 자동 지급 안 함.

이 정책은 룰 별 명시. 일부 기능은 OFF 시 데이터 자체 접근 차단도 가능 (예: 임상시험 모드 같은 민감 기능).

### EP-922. UI 노출 (SHOULD)

- 비활성 기능의 UI 메뉴 / 버튼은 숨김 (또는 비활성 + tooltip "관리자 문의")
- 데이터는 있는데 토글이 OFF 된 케이스: 데이터 표시는 하되 새 생성 불가 표시

```tsx
const dayLaborerEnabled = await isFeatureEnabled(orgId, 'payroll.day_laborer');
return (
  <div>
    {dayLaborerEnabled ? (
      <Button onClick={register}>일용직 등록</Button>
    ) : (
      <Tooltip content="이 기능은 비활성 상태입니다.">
        <Button disabled>일용직 등록 (비활성)</Button>
      </Tooltip>
    )}
  </div>
);
```

---

## 4. 변경 (EP-930 ~ EP-939)

### EP-930. 변경 트랜잭션 (MUST)

토글 변경은 단일 트랜잭션:

```typescript
await db.$transaction(async (tx) => {
  // 1. 기존 row UPDATE 또는 INSERT
  await tx.payrollFeatureFlag.upsert({
    where: { /* unique */ },
    create: { ..., enabled: newValue, changedBy: actor.id },
    update: { enabled: newValue, changedBy: actor.id, changedAt: new Date(), reason }
  });
  // 2. audit log
  await writeAudit({
    actor: actor.id,
    action: 'payroll.feature_flag.changed',
    target: feature,
    metadata: { scope, before, after: newValue, reason }
  }, tx);
  // 3. 의존성 검증 (EP-940)
  await validateDependencies(tx, scope, feature, newValue);
});
// 4. 캐시 invalidate (트랜잭션 외부)
cache.deleteByPrefix(`${orgId}:`);
```

### EP-931. 변경 권한 (MUST)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 토글 조회 | ❌ | ❌ | ✅ (참조) | ✅ | ✅ |
| ORGANIZATION 토글 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| FACILITY 토글 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| TEAM 토글 변경 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 신규 feature_key 등록 (시스템) | ❌ | ❌ | ❌ | ❌ | ✅ |

### EP-935. 변경 사유 권고 (SHOULD)

`reason` 필드 필수는 아니지만 강력 권고. UI 에서 입력 강제 + 빈 값 경고. 추후 감사 / 분쟁 시 추적 자료.

---

## 5. 의존성 (EP-940 ~ EP-949)

### EP-940. 의존성 표 (MUST 동기)

| 토글 | 의존 (이게 ON 이어야 함) |
|---|---|
| `payroll.piecework` | `payroll.work_log_piecework_source` |
| `payroll.payslip_acknowledgment_required` | `payroll.payslip_email_delivery` |

### EP-941. 켜기 전 의존성 확인 (MUST)

A 가 B 를 의존하면, A 켜기 전에 B 가 이미 ON 이어야 함:

```typescript
async function validateDependencies(tx, scope, feature, newValue) {
  if (!newValue) return;  // OFF 는 의존성 무관

  const deps = DEPENDENCIES[feature] ?? [];
  for (const dep of deps) {
    const depEnabled = await isFeatureEnabledInTx(tx, scope, dep);
    if (!depEnabled) {
      throw new MissingDependencyError(
        `${feature} 켜려면 먼저 ${dep} 가 켜져 있어야 합니다.`
      );
    }
  }
}
```

### EP-942. 의존성을 끄려고 할 때 (MUST)

B 가 A 의 의존이고 A 가 ON 인 상태에서 B 를 끄려고 하면 거부:

```typescript
// 'payroll.work_log_piecework_source' OFF 시도 + 'payroll.piecework' 가 ON 이면 거부
const dependents = REVERSE_DEPENDENCIES[feature] ?? [];
for (const dep of dependents) {
  if (await isFeatureEnabledInTx(tx, scope, dep)) {
    throw new DependencyInUseError(
      `${dep} 가 켜져 있는 동안 ${feature} 를 끌 수 없습니다.`
    );
  }
}
```

---

## 6. 감사 / 모니터링 (EP-950 ~ EP-959)

### EP-950. 필수 audit 액션

| action | 시점 |
|---|---|
| `payroll.feature_flag.changed` | 토글 변경 |
| `payroll.feature_flag.dependency_blocked` | 의존성 위반 시도 |
| `payroll.feature_flag.access_denied` | 비활성 기능 접근 시도 |

### EP-951. Super 모니터링 화면 (Phase 2+)

- 조직별 토글 매트릭스 한 눈에 보기
- 최근 변경 이력 / 변경자
- 의존성 그래프 시각화

---

## 7. 참조

- 일용근로자 룰 (`payroll.day_laborer` 가 게이트): `day_laborer.md`
- 업무별 단가 룰 (`payroll.piecework` 가 게이트): `piecework.md`
- 권한: `../../../rules/permissions.md` § E-410
- 스키마: `../schemas/tables/payroll_feature_flags.sql`
- 카탈로그: 이 파일 § EP-900
