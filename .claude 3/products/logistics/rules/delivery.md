# 배송 (Delivery)

> **ID 범위**: EL-001 ~ EL-099
> **주제**: 배송 건의 전체 lifecycle (생성 / 배차 / 출고 / 추적 / 완료 / 취소 / 실패)
> **상위**: `INDEX.md`

---

## TL;DR

- **lifecycle (단방향)**: DRAFT → ASSIGNED → IN_TRANSIT → DELIVERED / FAILED / CANCELLED.
- **DELIVERY_DISPATCHED 이벤트가 inventory.OUT movement 의 트리거**. delivery 발행자가 외부 모듈에 영향.
- **DELIVERY_COMPLETED 이벤트가 payroll.WorkLog 의 트리거** (기사 인건비, source_type=`DELIVERY`).
- **멱등 (MUST)** — 같은 order / line 으로 delivery 중복 생성 방지. (organization_id, order_id, line_no) UNIQUE.
- **취소 가능 시점은 IN_TRANSIT 이전까지**. 그 이후는 RETURN 으로 처리 (`returns.md`).
- **수령자 정보 = PII** — 이름 / 주소 / 전화 마스킹 + 보존 기간 + 암호화.
- **재시도 (FAILED → 재배차)** — attempt_no 별도 row 또는 같은 row 의 attempt_count++ 정책.

핵심 ID: EL-010 (모델) / EL-020 (lifecycle) / EL-030 (멱등) / EL-040 (이벤트 발행) / EL-050 (취소) / EL-060 (PII)

---

## 1. 모델 (EL-001 ~ EL-019)

### EL-010. 핵심 필드 (MUST)

```sql
CREATE TABLE logistics_deliveries (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  facility_id     UUID,
  warehouse_id    UUID,                            -- 출발 창고
  order_id        VARCHAR(100),                    -- 외부 주문 시스템 ID
  order_line_no   SMALLINT,                        -- 주문 라인

  -- 분류
  direction       VARCHAR(10) NOT NULL,            -- OUTBOUND / RETURN (역배송)
  delivery_type   VARCHAR(20) NOT NULL,            -- STANDARD / EXPRESS / SAME_DAY / SCHEDULED
  carrier         VARCHAR(20) NOT NULL DEFAULT 'self',  -- self / cj / hanjin / korea_post / lotte

  -- 수령자 (PII — 마스킹 대상, EL-060)
  recipient_name      VARCHAR(100) NOT NULL,
  recipient_phone     VARCHAR(20)  NOT NULL,
  recipient_address   TEXT NOT NULL,
  recipient_postal    VARCHAR(10),

  -- 시간
  scheduled_at        TIMESTAMPTZ,                 -- 약속 시각
  dispatched_at       TIMESTAMPTZ,                 -- 출고 시각 (실제)
  expected_eta        TIMESTAMPTZ,                 -- ETA
  completed_at        TIMESTAMPTZ,                 -- 완료 시각

  -- 배차
  driver_id           UUID,                        -- ASSIGNED 이후 NOT NULL
  vehicle_id          UUID,
  route_id            UUID,                        -- 묶음 배송 시

  -- 상태 / 시도
  status              VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  attempt_count       SMALLINT NOT NULL DEFAULT 0,
  cancel_reason       TEXT,
  fail_reason         TEXT,

  -- 외부 추적 번호 (carrier 발행)
  tracking_no         VARCHAR(50),

  -- 메타
  meta                JSONB,
  created_by          UUID NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ,

  UNIQUE (organization_id, order_id, order_line_no)  -- 멱등 (EL-030)
);
```

### EL-015. delivery_lines (배송 품목)

```sql
CREATE TABLE logistics_delivery_lines (
  id              UUID PRIMARY KEY,
  delivery_id     UUID NOT NULL,
  item_id         UUID NOT NULL,
  lot_id          UUID,                            -- inventory 와 정합
  serial_id       UUID,
  qty             NUMERIC(14, 4) NOT NULL,
  unit_price      NUMERIC(14, 0),                  -- 매출 / 정산용 (옵션)
  meta            JSONB,
  UNIQUE (delivery_id, item_id, lot_id, serial_id)
);
```

---

## 2. Lifecycle (EL-020 ~ EL-029) — MUST

### EL-020. 상태 머신 (단방향)

```
DRAFT  →  ASSIGNED  →  IN_TRANSIT  →  DELIVERED    (정상)
                              ↓
                          FAILED  →  ASSIGNED (재배차)
                              ↓
                          CANCELLED (재시도 한도 초과)
DRAFT  →  CANCELLED  (배차 전 취소)
ASSIGNED → CANCELLED  (배차 후 출발 전 취소)
```

| 상태 | 의미 | 출발 가능 전이 |
|---|---|---|
| `DRAFT` | 생성됨, 배차 전 | ASSIGNED, CANCELLED |
| `ASSIGNED` | 기사 / 차량 배정됨 | IN_TRANSIT, CANCELLED |
| `IN_TRANSIT` | 출발 후 (창고 출고 완료) | DELIVERED, FAILED |
| `DELIVERED` | 수령 완료 (POD 확정) | (종결) |
| `FAILED` | 배송 실패 (수령 거부 / 부재) | ASSIGNED (재배차), CANCELLED |
| `CANCELLED` | 취소됨 | (종결) |

역방향 / skip 전이 금지. 강제 변경은 Super 권한 + audit (EL-090).

### EL-025. 전이 검증 (MUST)

```typescript
const VALID_TRANSITIONS: Record<Status, Status[]> = {
  DRAFT:      ['ASSIGNED', 'CANCELLED'],
  ASSIGNED:   ['IN_TRANSIT', 'CANCELLED'],
  IN_TRANSIT: ['DELIVERED', 'FAILED'],
  FAILED:     ['ASSIGNED', 'CANCELLED'],
  DELIVERED:  [],
  CANCELLED:  [],
};

async function transitionDelivery(id, newStatus) {
  const d = await db.delivery.findUnique({ where: { id }});
  if (!VALID_TRANSITIONS[d.status].includes(newStatus)) {
    throw new InvalidTransitionError(`${d.status} → ${newStatus}`);
  }
  // ... 전이 + 이벤트 발행
}
```

---

## 3. 멱등 (EL-030 ~ EL-039)

### EL-030. order × line 단위 unique (MUST)

같은 (organization, order_id, order_line_no) 로 delivery 가 이미 있으면 INSERT 거부.

`ORDER_CONFIRMED` 이벤트 핸들러:
```typescript
async function handleOrderConfirmed(event) {
  const processed = await db.processedEvent.findUnique({ where: { eventId: event.id }});
  if (processed) return;

  await db.$transaction(async (tx) => {
    for (const line of event.lines) {
      try {
        await tx.delivery.create({
          data: {
            organizationId: event.orgId, orderId: event.orderId,
            orderLineNo: line.no, /* ... */
            status: 'DRAFT'
          }
        });
      } catch (e) {
        if (isUniqueViolation(e)) continue;  // 멱등
        throw e;
      }
    }
    await tx.processedEvent.create({ data: { eventId: event.id }});
  });
}
```

### EL-035. RETURN delivery 의 멱등 (MUST)

반품 delivery 는 원 delivery 와 link. order_line_no 충돌 회피를 위해:
- `direction = 'RETURN'` 이면 `order_id = original_delivery.id` (UUID), `order_line_no = NULL` 또는 별도 키
- 또는 별도 `parent_delivery_id` 컬럼 + UNIQUE 이쪽으로 (`returns.md` EL-510 참조)

---

## 4. 이벤트 발행 (EL-040 ~ EL-049) — MUST

### EL-040. outbox 패턴 (MUST)

상태 전이 트랜잭션 안에서 outbox 에 이벤트 INSERT. 별도 publisher worker 가 비동기 발행:

```typescript
await db.$transaction(async (tx) => {
  // 1. delivery 상태 전이
  await tx.delivery.update({ /* ... */ });
  // 2. outbox INSERT
  await tx.eventOutbox.create({
    data: {
      eventType: 'DELIVERY_DISPATCHED',
      payload: { deliveryId: id, dispatchedAt, items },
      aggregateType: 'delivery',
      aggregateId: id
    }
  });
});
// publisher worker 가 outbox 폴링 → 실 발행
```

### EL-045. inventory / payroll 정합 (MUST)

이벤트 영향 매트릭스:

| Delivery 전이 | 발행 이벤트 | 외부 모듈 영향 |
|---|---|---|
| DRAFT 생성 | `DELIVERY_DRAFTED` | inventory: reservation 생성 (옵션) |
| ASSIGNED | `DELIVERY_ASSIGNED` | (외부 알림 / 추적) |
| IN_TRANSIT | `DELIVERY_DISPATCHED` | **inventory: OUT movement (예약 → 실 출고)** |
| DELIVERED | `DELIVERY_COMPLETED` | **payroll: WorkLog (기사 인건비)** |
| FAILED | `DELIVERY_FAILED` | (운영자 알림) |
| CANCELLED (IN_TRANSIT 전) | `DELIVERY_CANCELLED` | inventory: reservation 해제 |
| CANCELLED (IN_TRANSIT 후) | (불가 — RETURN 으로) | — |

### EL-048. 이벤트 누락 방어 (MUST)

outbox 폴링 worker 다운 / 메시지 큐 장애:
- outbox row 는 트랜잭션 보존 → 시스템 복구 시 자동 재발행
- 같은 이벤트 여러 번 발행 가능성 → 수신측 멱등 처리 의무

---

## 5. 취소 / 실패 / 재시도 (EL-050 ~ EL-069)

### EL-050. 취소 시점별 처리 (MUST)

| 시점 | 처리 |
|---|---|
| DRAFT 취소 | 단순 `status = CANCELLED` |
| ASSIGNED 취소 | reservation 해제 + 운전자에게 알림 + 재배차 큐에서 제거 |
| IN_TRANSIT 취소 | **불가** — RETURN 으로 처리 (`returns.md`) |
| DELIVERED 취소 | **불가** — RETURN 으로 처리 |

```typescript
if (delivery.status === 'IN_TRANSIT') {
  throw new CancellationNotAllowedError('IN_TRANSIT 이후는 RETURN 으로 처리하세요.');
}
```

### EL-055. FAILED 사유 분류 (MUST)

| 사유 | 재배차 가능 | 비고 |
|---|---|---|
| 수령자 부재 | ✅ (재시도) | attempt_count++ |
| 주소 오류 | ✅ (주소 정정 후) | 운영자 개입 |
| 수령 거부 | ⚠️ (RETURN 권장) | 정책 분기 |
| 차량 사고 / 분실 | ❌ (CANCELLED + 보험 처리) | 보험 모듈 (Phase 2+) |
| 시간 초과 (배달 불가) | ✅ (재시도) | SLA 정책 |

### EL-060. 재시도 한도 (MUST)

조직 정책 — 기본 3회. attempt_count > limit → 자동 CANCELLED + 운영자 알림.

```typescript
if (delivery.attemptCount >= MAX_DELIVERY_ATTEMPTS) {
  await transitionDelivery(delivery.id, 'CANCELLED');
  // RETURN delivery 자동 생성 (옵션)
}
```

---

## 6. PII / 위치 정보 (EL-070 ~ EL-089) — MUST, KR

### EL-070. 수령자 정보 마스킹 (MUST)

근거: 개인정보보호법 §15 (수집 / 이용), §29 (안전조치).

표시 마스킹:
- `recipient_name`: "홍**" (성 + 마스킹)
- `recipient_phone`: "010-****-1234" (가운데 4자리)
- `recipient_address`: "서울특별시 강남구 ***" (상세주소 마스킹)

L2 (현장 작업자 / 기사) 는 배송 진행 시점에만 풀 정보 접근. 완료 후 마스킹.

### EL-075. 보존 기간 (MUST)

- 배송 완료 후 **5년** (전자상거래법 §6 § 3 — 거래기록 보존)
- 5년 경과 시 자동 마스킹 / 삭제 (cron + audit)

### EL-080. 운전자 위치 로깅 (MUST, opt-in)

토글 `logistics.driver_location_logging = ON` + 운전자 동의 (PII 처리 동의서) 동시 충족 시만 위치 저장.

저장 시:
- 위치 = 좌표 (lat / lng) NUMERIC(10, 7)
- 시간 = 1분 단위 그라뉼래리티 (분 단위 이하 X)
- 보존: 배송 완료 후 30일, 그 이후 익명화 (운전자 ID 분리)
- 암호화 컬럼 (pgcrypto 또는 application-level)

---

## 7. 권한 (EL-080 ~ EL-089)

| 작업 | L1 | L2 (기사) | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 배정 delivery 조회 | — | ✅ | ✅ | ✅ | ✅ |
| Delivery 생성 (수동) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 배차 (ASSIGNED 전이) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 출발 / IN_TRANSIT 전이 (기사 본인) | ❌ | ✅ (배정된 건) | ✅ | ✅ | ⚠️ |
| DELIVERED 전이 (POD 등록) | ❌ | ✅ (배정된 건) | ✅ | ✅ | ⚠️ |
| FAILED 전이 | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 취소 (DRAFT / ASSIGNED) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 강제 상태 변경 | ❌ | ❌ | ❌ | ⚠️ | ✅ + audit |
| 수령자 PII 마스킹 해제 | ❌ | ✅ (배송 중만) | ✅ | ✅ | ✅ |

---

## 8. 감사 (EL-090 ~ EL-099)

| action | 시점 |
|---|---|
| `logistics.delivery.drafted` | DRAFT 생성 |
| `logistics.delivery.assigned` | 배차 |
| `logistics.delivery.dispatched` | IN_TRANSIT |
| `logistics.delivery.completed` | DELIVERED + POD |
| `logistics.delivery.failed` | FAILED |
| `logistics.delivery.cancelled` | CANCELLED |
| `logistics.delivery.transition_blocked` | 잘못된 전이 시도 |
| `logistics.delivery.pii_unmasked` | PII 풀 조회 (actor + scope) |
| `logistics.delivery.force_status_change` | Super 강제 전이 |

---

## 9. 참조

- 게이트: `feature_flags.md` (`logistics.self_delivery`, `logistics.carrier_*`)
- 기사 / 차량: `driver_vehicle.md` (EL-100~)
- 추적 / POD: `tracking_pod.md` (EL-300~)
- 운임: `shipping_cost.md` (EL-400~)
- 반품: `returns.md` (EL-500~)
- inventory 정합: `../../inventory/rules/stock_movement.md` (EI-100~)
- payroll WorkLog: `../../payroll/rules/work_log.md` (EP-100~)
- 스키마: `../schemas/tables/logistics_deliveries.sql`
