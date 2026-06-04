# 모듈 간 통합 / 이벤트 (Integration)

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (4-모듈 통합)
> **참조**: 각 모듈 `rules/INDEX.md` § 4 (외부 약속), `./permissions.md`

---

## 0. 적용 범위

이 문서는 **payroll / inventory / logistics / reports** 4 모듈 간의 통합 패턴을 정의한다:

- 이벤트 카탈로그 (PUB / SUB)
- 메시지 페이로드 표준
- 멱등성 / 재시도 정책
- 시퀀스 다이어그램 (핵심 흐름)
- 외부 시스템 연동 (carrier / ESP / 회계 / 세무)

각 모듈 룰은 이 문서의 메커니즘을 준수한다.

---

## 1. 이벤트 시스템 아키텍처

### 1.1 outbox 패턴 (MUST)

모든 이벤트 발행은 **outbox** 패턴 — 비즈니스 트랜잭션과 같은 트랜잭션 안에서 outbox 테이블에 INSERT, 별도 worker 가 비동기 publish.

```
┌──────────────────────────────────────────────────┐
│  Business Transaction (atomic)                   │
│  ┌─────────────────────┐  ┌────────────────────┐ │
│  │ Domain UPDATE       │  │ event_outbox       │ │
│  │ (delivery, payment, │  │ INSERT             │ │
│  │  movement, ...)     │  │ (eventType, payload│ │
│  │                     │  │  aggregateId)      │ │
│  └─────────────────────┘  └────────────────────┘ │
└──────────────────────────────────────────────────┘
                            │
                            ▼  (commit 후)
                  ┌─────────────────────┐
                  │ Outbox Publisher    │
                  │ Worker (poll)       │
                  └──────────┬──────────┘
                             │
                             ▼
                  ┌─────────────────────┐
                  │ Event Bus / MQ      │
                  │ (in-memory / SQS /  │
                  │  Pub/Sub / Kafka)   │
                  └──────────┬──────────┘
                             │
                ┌────────────┼────────────┐
                ▼            ▼            ▼
            handler 1    handler 2    handler N
            (멱등 처리)
```

### 1.2 메시지 형식 표준 (MUST)

```typescript
interface DomainEvent<TPayload> {
  eventId: string;             // UUID, 멱등 키
  eventType: string;           // 'logistics.delivery.dispatched'
  occurredAt: string;          // ISO 8601 UTC
  organizationId: string;      // 멀티테넌트 격리
  aggregateType: string;       // 'delivery', 'payment', 'movement'
  aggregateId: string;
  version: number;             // 스키마 버전 (호환성)
  correlationId?: string;      // 트래이스 (saga / 외부 트리거 추적)
  causationId?: string;        // 인과 관계 (이전 이벤트 ID)
  payload: TPayload;
  metadata?: Record<string, unknown>;
}
```

### 1.3 멱등 처리 (MUST)

수신측은 **2중 방어**:

1. **`processed_events` 테이블** — `eventId` UNIQUE
2. **자연 키 UNIQUE** — 도메인 모델의 자연 키 (예: `(organization_id, source_type, source_id)`)

```typescript
async function handleEvent(event: DomainEvent<any>) {
  await db.$transaction(async (tx) => {
    try {
      await tx.processedEvent.create({ data: { eventId: event.eventId, eventType: event.eventType }});
    } catch (e) {
      if (isUniqueViolation(e)) return;   // 이미 처리됨
      throw e;
    }
    // 비즈니스 로직 (자연 키 UNIQUE 도 검증)
    await processBusinessLogic(tx, event);
  });
}
```

### 1.4 At-least-once 전달 (MUST)

이벤트 손실 방지 = at-least-once. 수신측 멱등 처리로 중복 영향 제거.

이유:
- outbox publisher 다운 / 재시작 → outbox row 보존, 재발행
- 메시지 큐 장애 → 재전송
- handler 처리 중 실패 → 메시지 ack 안 함, 재처리

### 1.5 Saga (분산 트랜잭션) (Phase 1+)

여러 모듈에 걸친 트랜잭션은 **saga** 패턴 — 보상 트랜잭션으로 일관성 유지.

예: `ORDER_CONFIRMED` saga
1. logistics: Delivery DRAFT 생성
2. inventory: reservation 생성
3. (실패 시) inventory: reservation 취소 → logistics: Delivery 취소

상세는 `@erp-harness/core` saga 모듈.

---

## 2. 이벤트 카탈로그 (전체 PUB/SUB)

### 2.1 명명 규약 (MUST)

`{module}.{aggregate}.{verb}` (snake_case + dot)

예:
- `logistics.delivery.dispatched`
- `payroll.payment.confirmed`
- `inventory.movement.recorded`
- `report.run.succeeded`

verb 패턴:
- `*.recorded` — 사실 기록 (movement / attendance)
- `*.confirmed` — 승인 / 완료 (payment / work_log)
- `*.dispatched` / `.completed` / `.failed` — lifecycle 전이
- `*.cancelled` — 취소
- `*.closed` — 마감 (period / month)
- `*.changed` — 변경 (feature_flag / setting)

### 2.2 이벤트 매트릭스

| 이벤트 | 발행자 | 페이로드 핵심 | 주요 소비자 |
|---|---|---|---|
| **payroll** | | | |
| `payroll.attendance.recorded` | payroll | userId / facilityId / type / at | (없음, 향후 BI) |
| `payroll.work_log.confirmed` | payroll | userId / period / amount / source | reports |
| `payroll.salary.calculated` | payroll | userId / period / gross / net | reports |
| `payroll.payment.confirmed` | payroll | userId / amount / paidAt | reports (캐시 무효화) |
| `payroll.period.closed` | payroll | period / closedBy | reports (immutable 마킹) |
| `payroll.feature_flag.changed` | payroll | feature_key / scope / enabled | (운영 알림) |
| **inventory** | | | |
| `inventory.movement.recorded` | inventory | itemId / warehouseId / qty / direction | (없음, 향후 BI) |
| `inventory.balance.adjusted` | inventory | itemId / warehouseId / oldQty / newQty | reports (캐시 무효화) |
| `inventory.reservation.created` | inventory | itemId / qty / sourceType / sourceId | logistics (정합) |
| `inventory.reservation.released` | inventory | itemId / qty / sourceId | logistics |
| `inventory.lot.expired` | inventory | lotId / itemId / expiredAt | logistics (배송 알림) |
| `inventory.lot.recalled` | inventory | lotId / reason | logistics (배송 차단) |
| `inventory.cycle_count.completed` | inventory | countId / discrepancies | reports (캐시 무효화) |
| `inventory.month_closed` | inventory | period / closedBy | reports (immutable) |
| `inventory.feature_flag.changed` | inventory | feature_key | |
| **logistics** | | | |
| `logistics.delivery.drafted` | logistics | deliveryId / orderId / items | inventory (reservation) |
| `logistics.delivery.assigned` | logistics | deliveryId / driverId / vehicleId | (외부 알림) |
| `logistics.delivery.dispatched` | logistics | deliveryId / dispatchedAt / items | **inventory** (OUT) |
| `logistics.delivery.completed` | logistics | deliveryId / podId / driverId | **payroll** (work_log) + reports |
| `logistics.delivery.failed` | logistics | deliveryId / reason | (운영 알림) |
| `logistics.delivery.cancelled` | logistics | deliveryId / reason | inventory (reservation 해제) |
| `logistics.return.received` | logistics | originalDeliveryId / returnDeliveryId | **inventory** (IN, RETURN) |
| `logistics.return.refunded` | logistics | runId / amount / reason | reports + 외부 결제 시스템 |
| `logistics.feature_flag.changed` | logistics | feature_key | |
| **reports** | | | |
| `report.run.started` | reports | runId / definitionCode / triggeredBy | (모니터링) |
| `report.run.succeeded` | reports | runId / rowCount / fileSize | (운영 알림) |
| `report.run.failed` | reports | runId / error | (운영 알림) |
| `report.run.finalized` | reports | runId / period | (감사) |
| `report.distribution.sent` | reports | distributionId / channel / piiLevel | (감사) |
| `report.feature_flag.changed` | reports | feature_key | |

### 2.3 외부 발행 이벤트

조직 외부 시스템 (회계 / 세무 / BI) 으로 발행하는 이벤트:

| 외부 시스템 | 이벤트 | 페이로드 |
|---|---|---|
| 회계 GL (Phase 1+) | `payroll.payment.confirmed` | journal entries (차변/대변) |
| 회계 GL (Phase 1+) | `inventory.month_closed` | 재고 평가액 분개 |
| 외부 결제 시스템 | `logistics.return.refunded` | 환불 트리거 |
| BI / DataLake (Phase 2+) | 모든 `*.recorded` / `*.confirmed` | 분석용 raw 데이터 |

---

## 3. 외부 구독 이벤트 (수신)

### 3.1 외부 발행자 → 4 모듈

| 이벤트 | 발행자 | 처리 모듈 | 처리 |
|---|---|---|---|
| `ORDER_CONFIRMED` | 주문 시스템 (외부) | **logistics + inventory** | logistics: Delivery DRAFT, inventory: reservation |
| `ORDER_CANCELLED` | 주문 시스템 | logistics | Delivery 취소 (IN_TRANSIT 후는 거부) |
| `CARRIER_TRACKING_UPDATE` | CJ / 한진 / 우체국 (webhook) | logistics | tracking_event INSERT (멱등) |
| `EMAIL_BOUNCED` | ESP (SendGrid 등) | reports | distribution status = BOUNCED |
| `INVOICE_RECEIVED` (Phase 1+) | 외부 carrier 청구 | logistics | settlement 정합 검증 |

### 3.2 외부 webhook 보안 (MUST)

모든 외부 → 내부 webhook:
- HMAC 서명 검증 (carrier / ESP)
- IP 화이트리스트 (가능 시)
- 멱등 (event_id UNIQUE)
- 토큰 / signed URL 인증

```typescript
async function verifyWebhook(req, secretKey) {
  const signature = req.headers['x-signature'];
  const body = await req.text();
  const expected = hmacSha256(body, secretKey);
  if (!timingSafeEqual(signature, expected)) {
    throw new InvalidSignatureError();
  }
}
```

---

## 4. 핵심 시퀀스 다이어그램

### 4.1 주문 → 출고 → 수령 → 인건비

```
주문                Logistics       Inventory       Payroll          Reports
시스템              (Delivery)      (Stock)         (WorkLog)        (Cache)
  │                    │              │                │                │
  │ ORDER_CONFIRMED    │              │                │                │
  ├───────────────────→│              │                │                │
  │                    │              │                │                │
  │             Delivery DRAFT 생성   │                │                │
  │                    ├─ outbox ──→ DELIVERY_DRAFTED  │                │
  │                    │              │                │                │
  │                    │              │ reservation 생성│                │
  │                    │              ├─ inventory.    │                │
  │                    │              │   reservation. │                │
  │                    │              │   created     │                │
  │                    │              │                │                │
  │             [기사 출발]            │                │                │
  │             상태: IN_TRANSIT       │                │                │
  │                    ├─ outbox ──→ DELIVERY_DISPATCHED                │
  │                    │              │                │                │
  │                    │              │ OUT movement 생성               │
  │                    │              │ (lot_id 보존)   │                │
  │                    │              ├─ inventory.    │                │
  │                    │              │   movement.    │                │
  │                    │              │   recorded    │ 캐시 invalidate  │
  │                    │              │                │←──────────────│
  │                    │              │                │                │
  │             [POD 등록 + DELIVERED]                  │                │
  │                    ├─ outbox ──→ DELIVERY_COMPLETED                 │
  │                    │              │                │                │
  │                    │              │              WorkLog 자동 생성  │
  │                    │              │              (source=DELIVERY)  │
  │                    │              │                ├ payroll.work_  │
  │                    │              │                │  log.confirmed │
  │                    │              │                │ ───────────────→
  │                    │              │                │  캐시 invalidate│
```

상세 (각 모듈 내부):
- inventory OUT: lot_id 보존, FIFO 레이어 차감 / 이동평균 갱신
- payroll WorkLog: 기사 compensation_settings 기반 amount 산출 (per_delivery / per_distance / per_time)

### 4.2 반품 → 환원 → 환불

```
고객              Logistics         Inventory       외부 결제       Reports
                  (Return)          (Stock)         시스템          (Cache)
 │                   │                │                │                │
 │ 반품 요청         │                │                │                │
 ├──────────────────→│                │                │                │
 │              REQUESTED → APPROVED  │                │                │
 │                   │                │                │                │
 │              RETURN delivery 생성  │                │                │
 │              (parent_id, direction='RETURN')        │                │
 │                   ├─ outbox ──→ DELIVERY_DRAFTED   │                │
 │                   │                │                │                │
 │              [수거 → 창고 도착]    │                │                │
 │              상태: RECEIVED        │                │                │
 │                   │                │                │                │
 │                   │              IN movement 생성   │                │
 │                   │              (RETURN, lot 보존) │                │
 │                   │                │                │                │
 │              [검수 → INSPECTED]   │                │                │
 │              결과: PASS / FAIL    │                │                │
 │                   │                │                │                │
 │              환불 발행 (PASS 시)   │                │                │
 │                   ├─ outbox ──→ logistics.return.refunded            │
 │                   │              ├─────────────────→│                │
 │                   │                │              환불 처리          │
 │                   │                │                │ 캐시 invalidate │
 │                   │                │                │ ────────────→ │
 │←─────────── 환불 통보 ───────────────────────────────│                │
```

cost_bearer 자동 분기 (전자상거래법 §17/§18):
- 단순변심 (CUSTOMER_REGRET) → BUYER (고객 부담, 배송비 차감)
- 하자 / 오배송 (DEFECT / WRONG_ITEM) → SELLER (왕복 배송비 부담)
- 운송 중 파손 (DAMAGED_TRANSIT) → CARRIER 또는 SELLER

### 4.3 월결산 (period close → reports immutable)

```
운영자          Payroll       Inventory     Logistics     Reports
                              (Stock)       (Delivery)
  │               │              │              │              │
  │ 월결산 요청   │              │              │              │
  ├──────────────→│              │              │              │
  │              [급여 마감]      │              │              │
  │              period_closed    │              │              │
  │               ├─ outbox ──→ payroll.period.closed           │
  │               │              │              │              │
  │               │              │              │      해당 기간 │
  │               │              │              │      SUCCESS   │
  │               │              │              │      report_runs│
  │               │              │              │      모두      │
  │               │              │              │      is_immutable│
  │               │              │              │      = true    │
  │               │              │              │              │
  ├─────────────────────────────→│              │              │
  │               │           [재고 마감]        │              │
  │               │           month_closed        │              │
  │               │              ├─ inventory.month.closed      │
  │               │              │              │              │
  │               │              │              │      [동일 처리]│
```

period_closed 이후:
- 그 기간 movement / payment / work_log 변경 차단
- reports 의 SUCCESS run 들 immutable
- 재실행 / 재생성은 Super 강제만 (강화 audit)

### 4.4 보고서 자동 스케줄 → 마감 대기 → 생성 → 배포

```
Cron Worker      Reports         Payroll          Email ESP
                 (Schedule)
  │               │              │                │
  │ 매분 polling  │              │                │
  ├──────────────→│              │                │
  │             다음 실행 schedule │                │
  │             nextRunAt <= now  │                │
  │               │              │                │
  │             checkAndTrigger   │                │
  │             (마감 대기 검증)  │                │
  │               ├──────────────→│                │
  │               │ period 마감?  │                │
  │               │              │                │
  │       case 1: 미마감          │                │
  │             postpone (다음 cron)               │
  │               │              │                │
  │       case 2: 마감 후 24h 경과 │                │
  │             startReportRun   │                │
  │             큐 등록 (PENDING) │                │
  │               │              │                │
  │             [Worker 처리]     │                │
  │             RUNNING → SUCCESS │                │
  │             결과 파일 생성    │                │
  │             외부 storage 업로드│                │
  │               │              │                │
  │             자동 발송 schedule │                │
  │             (이메일 토글 ON 시)│                │
  │               ├───────────────────────────────→│
  │               │ 첨부 (10MB 이하) 또는 signed URL                  │
  │               │              │                │
  │               │←──────────────────────────────│
  │               │ delivered    │                │
  │             distribution.sent │                │
```

---

## 5. 페이로드 표준 (이벤트별)

### 5.1 logistics.delivery.dispatched (MUST)

```typescript
interface DeliveryDispatchedPayload {
  deliveryId: string;
  warehouseId: string;
  dispatchedAt: string;     // ISO 8601 UTC
  items: Array<{
    itemId: string;
    lotId?: string;
    serialId?: string;
    qty: number;
  }>;
  driverId?: string;        // self 배송 시
  vehicleId?: string;
  carrier: string;          // 'self' / 'cj' / ...
  trackingNo?: string;      // 외부 carrier 시
}
```

### 5.2 logistics.delivery.completed (MUST)

```typescript
interface DeliveryCompletedPayload {
  deliveryId: string;
  driverId?: string;
  completedAt: string;
  podId: string;
  recipientKind: 'SELF' | 'DELEGATE' | 'DOORSTEP' | 'SECURITY';
  // payroll work_log 산출에 필요한 메타
  distanceKm?: number;
  durationMinutes?: number;
}
```

### 5.3 inventory.movement.recorded (MUST)

```typescript
interface MovementRecordedPayload {
  movementId: string;
  itemId: string;
  warehouseId: string;
  locationId?: string;
  lotId?: string;
  direction: 'IN' | 'OUT' | 'TRANSFER' | 'ADJUSTMENT';
  qty: number;
  signedQty: number;
  // sourceType: inventory movement_source ENUM 의 9 값 중 하나 (v0.2 기준)
  // PURCHASE / ORDER / DELIVERY / MANUAL / COUNT_ADJUSTMENT
  // / REVERSAL / TRANSFER_INTERNAL / EXPIRY_DISPOSAL / RETURN
  sourceType: string;
  sourceId: string;        // 형식: 'po:...' / 'ord:...' / 'dlv:...' / 'man:...' / 'rtn:...' 등
  unitCost?: number;
  totalCost?: number;
  occurredAt: string;
}
```

### 5.4 payroll.payment.confirmed (MUST)

```typescript
interface PaymentConfirmedPayload {
  paymentId: string;
  userId: string;
  period: string;           // 'YYYY-MM' / 'YYYY-Wnn' / 'YYYY-MM-DD'
  amount: number;           // KRW 정수
  scheme: 'salary' | 'hourly' | 'piecework' | 'commission' | 'day_laborer';
  paidAt: string;
  payslipId: string;
}
```

### 5.5 payroll.period.closed (MUST)

```typescript
interface PeriodClosedPayload {
  module: 'payroll' | 'inventory';
  period: string;           // 'YYYY-MM'
  facilityId?: string;      // 시설별 마감 시
  closedBy: string;
  closedAt: string;
  // 마감 대상 카운트 (검증)
  recordCount: {
    paymentsConfirmed?: number;
    movementsRecorded?: number;
  };
}
```

---

## 6. 재시도 정책 (MUST)

### 6.1 Outbox publisher

- 발행 실패 시 exponential backoff
- 시작 1s, 최대 5분, 최대 24시간 재시도
- 24시간 후에도 실패 → DLQ (dead-letter queue) + 운영 알림

### 6.2 Handler 처리

- 처리 실패 시 메시지 ack 안 함 → 자동 재전달
- DLQ 도달 시:
  - `*.recorded` / `*.confirmed` (사실 기록) → 운영 개입 필수
  - `*.cancelled` / `*.failed` → 자동 무시 가능 (영향 최소)
  - 캐시 무효화 / 알림 → 무시 가능 (다음 호출 시 재계산)

### 6.3 외부 webhook 호출 (carrier / ESP)

- 4xx (입력 오류) → 재시도 X, 운영자 알림
- 5xx / timeout → exponential backoff (3 회 재시도)
- 그래도 실패 → 사용자 알림 + 수동 재시도 버튼

---

## 7. 외부 시스템 연동 매트릭스

### 7.1 Carrier (logistics)

| Carrier | API | webhook | 멱등 키 | 비고 |
|---|---|---|---|---|
| CJ대한통운 | REST | webhook (HMAC) | carrier_event_id | 12자리 운송장 |
| 한진택배 | REST | webhook | event_id | 12자리 |
| 우체국택배 | REST | polling 기반 | tracking_no + status | 13자리 |
| 롯데택배 | REST | webhook | event_id | 12자리 |

dev / staging 환경 → mock 어댑터 강제 (실 운송장 발행 차단).

### 7.2 ESP (이메일, reports)

- 발송: SendGrid / SES / Mailgun (Phase 1+ 어댑터)
- DKIM / SPF 정상 도메인만
- bounce webhook → distribution status 갱신

### 7.3 결제 (외부, logistics 환불)

- 환불 트리거 = `logistics.return.refunded` 이벤트
- 외부 결제 시스템 (PG / 카드사) 이 처리
- 결제 시스템의 환불 완료 응답은 별도 webhook (Phase 1+ 정합)

### 7.4 회계 / GL (Phase 1+)

| 트리거 | 분개 |
|---|---|
| `payroll.payment.confirmed` | 차변: 인건비 / 대변: 현금 |
| `inventory.movement.recorded` (IN, PURCHASE) | 차변: 재고 / 대변: 매입채무 |
| `inventory.month_closed` | 차변/대변: 재고 평가 차이 |
| `logistics.return.refunded` | 차변: 매출 (-) / 대변: 미지급금 |

→ 외부 회계 모듈 (Phase 1+) 또는 GL 어댑터.

### 7.5 세무 / 신고 (Phase 1+)

- 4대보험 EDI: 정보화진흥원 표준 (월 단위 신고)
- 원천세 홈택스: 국세청 신고 (월)
- 부가가치세 홈택스: 분기

→ reports 모듈에서 자료 추출 후 외부 신고 시스템 (수동 / API).

---

## 8. 멀티테넌트 격리 (MUST)

### 8.1 organizationId 강제

모든 이벤트 페이로드에 `organizationId` 명시 (이벤트 envelope). 핸들러는:
- actor 의 organizationId 와 일치 여부 검증
- 다른 organization 데이터 처리 거부

### 8.2 시설 (facility) 스코프 (옵션)

같은 조직 내에서도 시설별 분리 시:
- `facilityScope` 검증 (`./permissions.md` § 2.2)
- 이벤트는 organization 단위 broadcast, 핸들러에서 시설 필터

### 8.3 cross-organization 트리거 (제한)

같은 organization 내에서만 cross-module 트리거 허용. 다른 organization 으로의 이벤트 누설 차단:
- outbox publisher 에 organizationId 검증
- handler 진입 시 organizationId 강제 매칭

---

## 9. 모니터링 / 관측 (MUST)

### 9.1 메트릭 (필수)

- outbox 큐 길이 (이벤트 발행 지연 지표)
- handler 처리 시간 (p50, p95, p99)
- 실패 / 재시도 비율 (모듈별, eventType 별)
- DLQ 도달 카운트 (운영 알림 기준)

### 9.2 로깅 / 추적

- correlation ID — saga / 요청 추적
- causation ID — 이벤트 인과 관계
- audit log — `./permissions.md` § 7

### 9.3 알림 임계값

| 지표 | 임계 | 알림 |
|---|---|---|
| outbox 큐 > 1000 | 5분 | 운영 (warn) |
| outbox 큐 > 10000 | 즉시 | 운영 (critical) |
| DLQ 메시지 발생 | 즉시 | 운영 (critical) |
| handler p95 > 30s | 10분 | 개발 |
| `*.failed` 이벤트 비율 > 5% | 1시간 | 운영 |

---

## 10. Phase 1+ 결정사항

- [ ] 큐 시스템 선택 (BullMQ / SQS / Pub/Sub / Kafka)
- [ ] outbox publisher worker 구현 — 모든 모듈 공통
- [ ] DLQ 정책 / 재처리 도구
- [ ] saga orchestration 패턴 (보상 트랜잭션)
- [ ] 외부 carrier / ESP 어댑터 실 구현
- [ ] 회계 GL 어댑터
- [ ] BI / DataLake export (Phase 2+)
- [ ] real-time dashboard / WebSocket (Phase 2+)

---

## 11. 참조

- 권한: `./permissions.md`
- DB 규약: `./database.md`
- 각 모듈 룰의 § 4 (외부 약속):
  - `../products/payroll/rules/INDEX.md` § 4
  - `../products/inventory/rules/INDEX.md` § 4
  - `../products/logistics/rules/INDEX.md` § 4
  - `../products/reports/rules/INDEX.md` § 4
- ERP Harness boilerplate (별도): `@erp-harness/core` 의 EventBus / Saga
