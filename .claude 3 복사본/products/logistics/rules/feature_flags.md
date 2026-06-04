# 모듈 기능 토글 (Feature Flags)

> **ID 범위**: EL-900 ~ EL-999
> **주제**: 조직 / 시설 레벨 logistics 하위 기능 토글
> **상위**: `INDEX.md`

> 메커니즘은 `payroll/rules/feature_flags.md` (EP-900) / `inventory/rules/feature_flags.md` (EI-900) 와 동일. logistics 모듈 카탈로그 / 의존성만 다룸.

---

## TL;DR

- **저장**: `logistics_feature_flags` (구조 동일, 모듈만 분리)
- **변경 권한**: L4 (조직) / Super (전체)
- **기본값**: 부가 carrier 어댑터는 모두 OFF. 안전 기능 (`pod_signature`, `pod_photo`, `delivery_sla_alerts`) 는 ON.
- **의존성** — `route_optimization`, `pod_*`, `driver_location_logging` 의 의존 / 상호 배타 검증.

핵심 ID: EL-910 (스키마) / EL-920 (런타임) / EL-940 (의존성)

---

## 1. 토글 카탈로그 (EL-900 ~ EL-909)

### EL-900. 정의된 토글 (MUST 동기 유지)

| feature_key | 기본값 | 룰 | 의존 |
|---|---|---|---|
| `logistics.self_delivery` | ON | `delivery.md`, `driver_vehicle.md` | — |
| `logistics.carrier_cj` | OFF | `carrier.md` | — |
| `logistics.carrier_hanjin` | OFF | `carrier.md` | — |
| `logistics.carrier_korea_post` | OFF | `carrier.md` | — |
| `logistics.carrier_lotte` | OFF | `carrier.md` | — |
| `logistics.route_optimization` | OFF | `route.md` (EL-230) | — |
| `logistics.real_time_tracking` | ON | `tracking_pod.md` (EL-310) | — |
| `logistics.pod_signature` | ON | `tracking_pod.md` (EL-325) | — |
| `logistics.pod_photo` | ON | `tracking_pod.md` (EL-325) | — |
| `logistics.pod_id_verification` | OFF | `tracking_pod.md` (EL-340) | — |
| `logistics.return_handling` | ON | `returns.md` | — |
| `logistics.delivery_sla_alerts` | ON | `delivery.md` (EL-260), `route.md` (EL-260) | — |
| `logistics.driver_location_logging` | OFF | `delivery.md` (EL-080), `tracking_pod.md` (EL-350) | `logistics.real_time_tracking` |
| `logistics.delivery_window_strict` | OFF | `delivery.md` (시간 약속 엄격) | — |
| `logistics.auto_carrier_routing` | OFF | `carrier.md` (EL-650) | 최소 2 carrier ON |

### EL-901. 명명 규약 (MUST)

`logistics.{subkey}` — payroll / inventory 와 동일.

---

## 2. 스키마 / 런타임 (EL-910 ~ EL-929)

### EL-910. logistics_feature_flags (MUST)

`payroll_feature_flags` / `inventory_feature_flags` 와 구조 동일:

```sql
CREATE TABLE logistics_feature_flags (
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

### EL-911. 스코프 우선순위 (MUST)

```
TEAM > FACILITY > ORGANIZATION > 기본값
```

logistics 는 보통 ORGANIZATION 단위. carrier 는 FACILITY 단위 분기 가능 (창고별 다른 carrier).

### EL-920. requireFeature (MUST)

기능 진입점에서 명시 체크 — payroll EP-920 동일.

```typescript
async function dispatchToCarrier(d, actor) {
  await requireFeature(actor.organizationId, `logistics.carrier_${d.carrier}`);
  // ... 어댑터 호출
}
```

---

## 3. 의존성 (EL-940 ~ EL-949) — MUST

### EL-940. 의존성 표

| 토글 | 의존 (이게 ON 필요) |
|---|---|
| `logistics.driver_location_logging` | `logistics.real_time_tracking` |
| `logistics.auto_carrier_routing` | (다음 중 ≥ 2 ON) `logistics.carrier_cj`, `_hanjin`, `_korea_post`, `_lotte` |
| `logistics.delivery_window_strict` | `logistics.real_time_tracking` |

### EL-945. 켜기 / 끄기 검증 (MUST)

A 가 B 를 의존하면 A 켜기 전 B 가 ON. payroll EP-941 / EP-942 와 동일 메커니즘.

### EL-948. 카운트 기반 의존 (MUST, logistics 한정)

`auto_carrier_routing` 은 **carrier 어댑터 ≥ 2** 일 때만 켤 수 있음:

```typescript
async function validateMinCarriersForAutoRouting(scope, newValue) {
  if (!newValue) return;
  const carrierToggles = ['carrier_cj', 'carrier_hanjin', 'carrier_korea_post', 'carrier_lotte'];
  let activeCount = 0;
  for (const c of carrierToggles) {
    if (await isFeatureEnabled(scope, `logistics.${c}`)) activeCount++;
  }
  if (activeCount < 2) {
    throw new InsufficientCarriersError('자동 라우팅을 켜려면 최소 2개의 carrier 가 활성화되어야 합니다.');
  }
}
```

---

## 4. PII / 동의 정합 (EL-950 ~ EL-959)

### EL-950. 운전자 위치 동의 (MUST)

`logistics.driver_location_logging = ON` 변경 시:
- 모든 active driver 의 동의 상태 검증
- 동의 X 인 driver 는 위치 수집 제외 (개인별 opt-in 별도 운영)
- 변경 audit 에 동의 인원 / 미동의 인원 명시

```typescript
if (newValue && feature === 'logistics.driver_location_logging') {
  const drivers = await db.driver.findMany({
    where: { status: 'ACTIVE', organizationId: scope.orgId }
  });
  const consented = drivers.filter(d => d.locationConsent === true).length;
  // audit log
  await writeAudit({
    action: 'logistics.feature_flag.location_logging_enabled',
    metadata: { totalDrivers: drivers.length, consented, missingConsent: drivers.length - consented }
  });
}
```

---

## 5. 권한 / 감사 (EL-980 ~ EL-999)

### EL-980. 권한

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 토글 조회 | ❌ | ❌ | ✅ | ✅ | ✅ |
| ORGANIZATION / FACILITY 토글 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| carrier 시크릿 조회 / 변경 | ❌ | ❌ | ❌ | ❌ | ✅ |

### EL-990. 감사

| action | 시점 |
|---|---|
| `logistics.feature_flag.changed` | 토글 변경 |
| `logistics.feature_flag.dependency_blocked` | 의존성 위반 |
| `logistics.feature_flag.location_logging_enabled` | 위치 로깅 활성화 (동의 인원 보고) |
| `logistics.feature_flag.auto_routing_blocked` | carrier 부족으로 자동 라우팅 거부 |

---

## 6. 참조

- 동일 메커니즘: `payroll/rules/feature_flags.md`, `inventory/rules/feature_flags.md`
- 룰 카탈로그: `INDEX.md` § 6
- 스키마: `../schemas/tables/logistics_feature_flags.sql`
