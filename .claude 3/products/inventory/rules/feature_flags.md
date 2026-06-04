# 모듈 기능 토글 (Feature Flags)

> **ID 범위**: EI-900 ~ EI-999
> **주제**: 조직 / 시설 레벨 inventory 하위 기능 토글
> **상위**: `INDEX.md`

> 이 룰은 `payroll/rules/feature_flags.md` (EP-900~999) 와 **동일 메커니즘**. inventory 모듈만의 카탈로그와 의존성을 다룸.

---

## TL;DR

- **저장 위치**: `inventory_feature_flags` (구조 동일, 모듈만 분리)
- **변경 권한**: L4 (조직) / Super (전체). L3 이하 토글 불가.
- **기본값**: 모든 신규 토글 OFF (보수적). 안전 토글 (negative_stock_block, expiry_block_ship 등) 만 ON.
- **변경 이력**: 모든 변경은 audit + 변경자 / 시점 / 사유.
- **의존성 검증** — 일부 토글은 다른 토글 ON 전제 (예: fefo_dispatch → lot_tracking).
- **런타임 체크** — 모든 기능 진입 시 `requireFeature(orgId, 'inventory.lot_tracking')`.

핵심 ID: EI-910 (스키마) / EI-920 (런타임) / EI-940 (의존성)

---

## 1. 토글 카탈로그 (EI-900 ~ EI-909)

### EI-900. 현재 정의된 토글 (MUST 동기 유지)

| feature_key | 기본값 | 룰 | 의존 |
|---|---|---|---|
| `inventory.lot_tracking` | OFF | `lot_tracking.md` | — |
| `inventory.serial_tracking` | OFF | `lot_tracking.md` (EI-320) | — |
| `inventory.multi_warehouse` | OFF | `warehouse.md` (EI-415) | — |
| `inventory.location_bin` | OFF | `warehouse.md` (EI-428) | `inventory.multi_warehouse` |
| `inventory.reservation` | ON | `stock_balance.md` (EI-220) | — |
| `inventory.fefo_dispatch` | OFF | `lot_tracking.md` (EI-330) | `inventory.lot_tracking` |
| `inventory.valuation_fifo` | ON | `valuation.md` (EI-610) | — |
| `inventory.valuation_moving_avg` | OFF | `valuation.md` (EI-620) | — |
| `inventory.cycle_count` | ON | `cycle_count.md` (EI-500) | — |
| `inventory.negative_stock_block` | ON | `stock_movement.md` (EI-140) | — |
| `inventory.expiry_block_ship` | ON | `lot_tracking.md` (EI-340) | `inventory.lot_tracking` |
| `inventory.kr_tax_invoice_link` | OFF | (Phase 1+) | — |

> **상호 배타**: `valuation_fifo` 와 `valuation_moving_avg` 는 둘 중 하나만 ON 가능. 둘 다 OFF 또는 둘 다 ON 은 차단 (EI-942).

### EI-901. 명명 규약 (MUST)

`{module}.{feature_subkey}` — payroll 과 동일 (EP-901).

```
✅ inventory.lot_tracking
✅ inventory.fefo_dispatch
❌ lot_tracking (모듈 prefix 없음)
❌ inventoryLotTracking (camelCase)
```

---

## 2. 스키마 (EI-910 ~ EI-919)

### EI-910. inventory_feature_flags 모델 (MUST)

`payroll_feature_flags` 와 구조 동일 (모듈만 분리):

```sql
CREATE TABLE inventory_feature_flags (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  scope_type      VARCHAR(20) NOT NULL,        -- ORGANIZATION / FACILITY / TEAM
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

### EI-911. 스코프 우선순위 (MUST)

```
TEAM > FACILITY > ORGANIZATION > 기본값 (EI-900)
```

payroll EP-911 과 동일 로직. 운영상 inventory 는 보통 ORGANIZATION 또는 FACILITY 단위 — TEAM 단위 토글은 드뭄.

---

## 3. 런타임 체크 (EI-920 ~ EI-929)

### EI-920. requireFeature 헬퍼 (MUST)

기능 진입점에서 명시 체크 — payroll EP-920 과 동일:

```typescript
async function createMovementWithLot(req, actor) {
  await requireFeature(actor.organizationId, 'inventory.lot_tracking', {
    facilityId: req.facilityId
  });
  // ... 본 로직
}
```

### EI-921. 비활성 데이터 (MUST)

토글 OFF 시:
- 읽기 허용 (이미 생성된 데이터)
- 새 생성 / 수정 차단
- 자동 작업 (배치) skip

예: `inventory.fefo_dispatch = OFF` 로 변경 → 기존 lot 조회는 가능. 새 출고 시 FEFO 정렬 안 함 (FIFO 로 fallback).

---

## 4. 변경 / 의존성 (EI-930 ~ EI-949)

### EI-930. 변경 트랜잭션 (MUST)

payroll EP-930 과 동일. UPSERT + audit + 의존성 검증 단일 트랜잭션. 캐시 invalidate.

### EI-940. 의존성 표 (MUST)

| 토글 | 의존 (이게 ON 필요) |
|---|---|
| `inventory.fefo_dispatch` | `inventory.lot_tracking` |
| `inventory.expiry_block_ship` | `inventory.lot_tracking` |
| `inventory.location_bin` | `inventory.multi_warehouse` |

### EI-941. 켜기 / 끄기 검증 (MUST)

- A 가 B 를 의존하면 A 켜기 전 B 가 ON
- B 끄려는데 A 가 ON 이면 거부

(payroll EP-941 / EP-942 와 동일 메커니즘)

### EI-942. 상호 배타 (MUST, inventory 한정)

`valuation_fifo` / `valuation_moving_avg` — **정확히 하나만 ON**:

```typescript
async function validateMutualExclusion(scope, feature, newValue) {
  const exclusiveGroups = {
    valuation_fifo: ['inventory.valuation_moving_avg'],
    valuation_moving_avg: ['inventory.valuation_fifo']
  };
  if (!newValue) return;
  const excludes = exclusiveGroups[feature.split('.')[1]] ?? [];
  for (const ex of excludes) {
    if (await isFeatureEnabled(scope, ex)) {
      throw new MutualExclusionError(`${feature} 와 ${ex} 는 동시에 ON 될 수 없습니다.`);
    }
  }
}
```

방법 변경은 회계 결산 시점만 (EI-630) — 토글 변경 자체는 시스템적으로 가능하지만, audit + 회계 정책 워크플로우와 조합.

---

## 5. 권한 / 감사 (EI-950 ~ EI-999)

### EI-950. 권한 (MUST)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 토글 조회 | ❌ | ❌ | ✅ | ✅ | ✅ |
| ORGANIZATION / FACILITY 토글 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| 신규 feature_key 등록 (시스템) | ❌ | ❌ | ❌ | ❌ | ✅ |

### EI-960. 감사

| action | 시점 |
|---|---|
| `inventory.feature_flag.changed` | 토글 변경 |
| `inventory.feature_flag.dependency_blocked` | 의존성 위반 |
| `inventory.feature_flag.mutual_exclusion_blocked` | 상호 배타 위반 |

---

## 6. 참조

- 동일 메커니즘 모듈: `payroll/rules/feature_flags.md` (EP-900~)
- 룰 카탈로그: `INDEX.md` § 6
- 스키마: `../schemas/tables/inventory_feature_flags.sql`
