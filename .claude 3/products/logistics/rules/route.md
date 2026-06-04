# 경로 / 묶음 배송 (Route)

> **ID 범위**: EL-200 ~ EL-299
> **주제**: 다(多) 배송 묶음, 방문 순서, 경로 최적화
> **상위**: `INDEX.md`
> **게이트 토글**: `logistics.route_optimization` (자동 최적화)

---

## TL;DR

- **route = 1 기사가 1 차량으로 1 회 운행하며 처리하는 다수 delivery 묶음**.
- **deliveries 1:N route** — 한 delivery 는 한 route 에 속함 (또는 NULL = 단일 배송).
- **방문 순서 = sequence_no** — route_stops 테이블에 (route_id, sequence_no) UNIQUE.
- **상태**: PLANNED → IN_PROGRESS → COMPLETED / CANCELLED.
- **route 시작 = 모든 소속 deliveries 함께 IN_TRANSIT 전이**. 출고 (inventory OUT) 도 route 단위 batch.
- **자동 최적화 (옵션)** — 토글 ON 시 외부 routing API (Google / TMap) 호출. OFF 시 수동 순서.
- **route 변경 정책** — IN_PROGRESS 후 추가 / 제거 제한 (수령 거부 / 우회 등 예외만).

핵심 ID: EL-210 (모델) / EL-220 (lifecycle) / EL-230 (최적화) / EL-240 (route 시작) / EL-250 (변경 제한)

---

## 1. 모델 (EL-200 ~ EL-219)

### EL-210. routes 테이블 (MUST)

```sql
CREATE TABLE logistics_routes (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  warehouse_id    UUID NOT NULL,                  -- 출발 창고
  driver_id       UUID,
  vehicle_id      UUID,
  scheduled_date  DATE NOT NULL,
  scheduled_start_at TIMESTAMPTZ,
  status          VARCHAR(20) NOT NULL DEFAULT 'PLANNED',
  -- PLANNED / IN_PROGRESS / COMPLETED / CANCELLED
  total_distance_km NUMERIC(10, 3),               -- 추정 / 실측
  total_stops     SMALLINT NOT NULL DEFAULT 0,
  optimization_method VARCHAR(20),                -- 'manual' / 'auto_google' / 'auto_tmap'
  optimized_at    TIMESTAMPTZ,
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE logistics_route_stops (
  id              UUID PRIMARY KEY,
  route_id        UUID NOT NULL,
  delivery_id     UUID NOT NULL,
  sequence_no     SMALLINT NOT NULL,              -- 방문 순서 (1, 2, 3, ...)
  estimated_arrival_at TIMESTAMPTZ,
  actual_arrival_at TIMESTAMPTZ,
  actual_departure_at TIMESTAMPTZ,
  distance_from_prev_km NUMERIC(10, 3),
  status          VARCHAR(20) NOT NULL DEFAULT 'PENDING',  -- PENDING / VISITED / SKIPPED
  UNIQUE (route_id, sequence_no),
  UNIQUE (route_id, delivery_id),
  CONSTRAINT fk_stops_route FOREIGN KEY (route_id) REFERENCES logistics_routes(id) ON DELETE CASCADE
);
```

### EL-215. delivery → route 연결

`logistics_deliveries.route_id` 컬럼:
- NULL = 단일 배송 (route 없음)
- NOT NULL = route 에 묶임. route_stops 와 정합 (UNIQUE 한쪽)

---

## 2. Lifecycle (EL-220 ~ EL-239)

### EL-220. 상태 머신 (MUST)

```
PLANNED  →  IN_PROGRESS  →  COMPLETED
   ↓             ↓
   └─── CANCELLED ←──┘
```

| 상태 | 의미 | 전이 |
|---|---|---|
| `PLANNED` | 생성됨, 출발 전 | IN_PROGRESS, CANCELLED |
| `IN_PROGRESS` | 출발 후 | COMPLETED, CANCELLED |
| `COMPLETED` | 모든 stop 처리 완료 | (종결) |
| `CANCELLED` | 취소 | (종결) |

### EL-225. 소속 deliveries 와 동기 전이 (MUST)

route 상태 전이 시 모든 소속 deliveries 도 함께:

| Route 전이 | 소속 deliveries 전이 |
|---|---|
| PLANNED → IN_PROGRESS | 모두 ASSIGNED → IN_TRANSIT 전이 (출발) |
| IN_PROGRESS → COMPLETED | 각 delivery 의 도착 시점에 개별 DELIVERED / FAILED |

route 전이는 트랜잭션. 모든 deliveries 정상 전이 가능해야 route 전이 성공:
```typescript
await db.$transaction(async (tx) => {
  const stops = await tx.routeStop.findMany({ where: { routeId }});
  for (const s of stops) {
    await transitionDelivery(tx, s.deliveryId, 'IN_TRANSIT');
  }
  await tx.route.update({ where: { id: routeId }, data: { status: 'IN_PROGRESS', startedAt: new Date() }});
});
```

---

## 3. 자동 최적화 (EL-230 ~ EL-249) — 토글

### EL-230. 외부 routing API (옵션)

토글 `logistics.route_optimization = ON` + 외부 API 키 설정 시:
- Google Routes API (`routes.googleapis.com`)
- TMap API (한국 내 정확)
- Naver Map Direction API

### EL-235. 호출 패턴 (MUST)

```typescript
async function optimizeRoute(routeId: string) {
  const route = await db.route.findUnique({ where: { id: routeId }, include: { stops: true }});
  const provider = await getRouteProvider(orgId);  // 'google' / 'tmap'

  const start = await getWarehouseLocation(route.warehouseId);
  const waypoints = route.stops.map(s => ({ lat: s.delivery.lat, lng: s.delivery.lng }));

  const result = await provider.optimize({ start, waypoints, returnToOrigin: true });

  // route_stops sequence_no 갱신
  await db.$transaction(async (tx) => {
    for (let i = 0; i < result.optimizedOrder.length; i++) {
      await tx.routeStop.update({
        where: { id: result.optimizedOrder[i].stopId },
        data: { sequenceNo: i + 1, distanceFromPrevKm: result.optimizedOrder[i].distance }
      });
    }
    await tx.route.update({
      where: { id: routeId },
      data: { totalDistanceKm: result.totalDistance, optimizedAt: new Date(),
              optimizationMethod: provider.name }
    });
  });
}
```

### EL-240. 호출 시점 (SHOULD)

- 자동: route PLANNED 상태에서 모든 stop 추가 후 (수동 트리거 / 스케줄)
- 수동: 운영자 버튼 ("경로 최적화")
- 호출 빈도 — 기본 1 route 1회. 변경 시 재호출 가능.

### EL-245. 결과 검증 (MUST)

외부 API 결과는 **추천**:
- 운영자가 결과 검토 후 적용
- 일부 stop 의 시간 약속 (delivery_window) 위배 시 자동 수정 X — 운영자 결정

---

## 4. 변경 제한 (EL-250 ~ EL-269)

### EL-250. PLANNED 단계 (MUST)

자유 — stop 추가 / 제거 / 순서 변경 가능. 자동 최적화 재실행 가능.

### EL-255. IN_PROGRESS 단계 (MUST)

원칙: stop 추가 / 제거 차단. 예외 케이스만 허용:

| 상황 | 허용 / 거부 |
|---|---|
| 수령 거부 → 다음 stop 으로 skip | ✅ status = SKIPPED |
| 도로 폐쇄 / 우회 (순서만 변경) | ✅ — 권한 L4 |
| 새 delivery 추가 | ❌ — 새 route 생성 |
| 기존 stop 제거 | ❌ — delivery 별도 처리 |

### EL-260. 시간 약속 (SLA) 위반 알림 (MUST, 토글 ON)

`logistics.delivery_sla_alerts = ON` 시:
- 각 stop 의 estimated_arrival_at 30분 초과 → 운영자 알림
- 수령자 알림 (옵션) — 도착 지연 안내 (PII 동의 시)

---

## 5. 권한 / 감사 (EL-280 ~ EL-299)

### EL-280. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| 본인 배정 route 조회 | ✅ | ✅ | ✅ | ✅ |
| route 생성 / 수정 (PLANNED) | ❌ | ✅ | ✅ | ⚠️ |
| 자동 최적화 호출 | ❌ | ✅ | ✅ | ⚠️ |
| route 시작 (IN_PROGRESS 전이) | ❌ | ✅ | ✅ | ⚠️ |
| route IN_PROGRESS 변경 | ❌ | ❌ | ✅ | ⚠️ |
| route 취소 | ❌ | ❌ | ✅ | ⚠️ |

### EL-290. 감사

| action | 시점 |
|---|---|
| `logistics.route.planned` | route 생성 |
| `logistics.route.optimized` | 자동 최적화 적용 |
| `logistics.route.started` | IN_PROGRESS |
| `logistics.route.stop_skipped` | 중간 SKIPPED |
| `logistics.route.completed` | 완료 |
| `logistics.route.modified_in_progress` | IN_PROGRESS 변경 (예외) |

---

## 6. 참조

- 게이트: `feature_flags.md` (`logistics.route_optimization`)
- delivery 전이: `delivery.md` § EL-020
- 추적 (실시간 위치): `tracking_pod.md`
- 스키마: `../schemas/tables/logistics_routes.sql`
