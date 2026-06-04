# 외부 배송사 (Carrier Adapters)

> **ID 범위**: EL-600 ~ EL-699
> **주제**: CJ대한통운 / 한진택배 / 우체국택배 / 롯데택배 등 외부 배송사 API 연동
> **상위**: `INDEX.md`
> **게이트**: `logistics.carrier_cj` / `carrier_hanjin` / `carrier_korea_post` / `carrier_lotte`

---

## TL;DR

- **carrier 어댑터 패턴 (Strategy)** — 통합 인터페이스 1개, carrier 별 구현체 N개. 토글로 활성화.
- **운송장 발행 (createWaybill)** — Delivery DRAFT → carrier API 호출 → tracking_no 반환 + ASSIGNED 전이.
- **추적 콜백 (webhook)** — carrier 가 위치 / 상태 업데이트 발신. tracking_events 멱등 INSERT.
- **공통 인터페이스**: `createWaybill / cancelWaybill / trackStatus / handleCallback / getQuote`.
- **테스트 / Sandbox** — 각 carrier 별 sandbox 환경. local / dev 는 무조건 mock.
- **API 키 / 시크릿 = secrets store** (`vault` / `aws-secrets-manager`). 환경변수 X.
- **요율 자동 동기 (옵션)** — 일배치로 carrier 단가표 가져와 `logistics_tariffs` 갱신.

핵심 ID: EL-610 (인터페이스) / EL-620 (운송장 발행) / EL-630 (콜백) / EL-650 (멀티 어댑터 라우팅) / EL-680 (KR 표준 carrier)

---

## 1. 어댑터 인터페이스 (EL-600 ~ EL-619)

### EL-610. 통합 인터페이스 (MUST)

```typescript
interface CarrierAdapter {
  readonly name: string;             // 'cj' / 'hanjin' / 'korea_post' / 'lotte'

  // 운송장 발행
  createWaybill(req: CreateWaybillRequest): Promise<WaybillResponse>;

  // 운송장 취소 (출고 전 가능)
  cancelWaybill(trackingNo: string, reason: string): Promise<void>;

  // 상태 조회 (polling 또는 사용자 요청)
  trackStatus(trackingNo: string): Promise<TrackingStatus>;

  // webhook 콜백 처리 — 멱등
  handleCallback(rawPayload: unknown, headers: Record<string, string>): Promise<void>;

  // 견적 (선택)
  getQuote(req: QuoteRequest): Promise<QuoteResponse>;
}

interface CreateWaybillRequest {
  orderId: string;
  recipient: { name: string; phone: string; address: string; postal: string };
  sender:    { name: string; phone: string; address: string; postal: string };
  items:     { name: string; qty: number; weight?: number; volume?: number }[];
  cod?:      number;        // 착불
  insuredValue?: number;
  expectedAt?: Date;
  meta?: Record<string, unknown>;
}

interface WaybillResponse {
  trackingNo: string;
  carrier: string;
  estimatedCost: number;
  estimatedAt?: Date;
  rawResponse?: unknown;    // 디버깅용 (PII 마스킹)
}
```

### EL-615. 어댑터 등록 (MUST)

```typescript
const adapters: Record<string, CarrierAdapter> = {
  cj:           new CjAdapter(secrets.cj),
  hanjin:       new HanjinAdapter(secrets.hanjin),
  korea_post:   new KoreaPostAdapter(secrets.koreaPost),
  lotte:        new LotteAdapter(secrets.lotte),
  mock:         new MockCarrierAdapter()
};

async function getAdapter(carrier: string, orgId: string): Promise<CarrierAdapter> {
  // 토글 검증
  await requireFeature(orgId, `logistics.carrier_${carrier}`);
  const adapter = adapters[carrier];
  if (!adapter) throw new CarrierNotConfiguredError(carrier);
  return adapter;
}
```

### EL-618. local / dev 환경 강제 (MUST)

```typescript
if (env.NODE_ENV !== 'production' && carrier !== 'mock') {
  throw new RealCarrierBlockedInDevError();
}
```

local / dev / staging 에서는 `mock` 어댑터만 허용. 실 API 호출 차단 (실 운송장 발행 사고 방지).

---

## 2. 운송장 발행 (EL-620 ~ EL-629)

### EL-620. createWaybill 호출 시점 (MUST)

Delivery 상태 전이 트랜잭션 안에서 호출 (DRAFT → ASSIGNED):

```typescript
async function assignDelivery(deliveryId, driverId, vehicleId) {
  const d = await db.delivery.findUnique({ where: { id: deliveryId }});

  // 외부 carrier 인 경우 API 호출
  let trackingNo: string | null = null;
  let estimatedCost: number | null = null;
  if (d.carrier !== 'self') {
    const adapter = await getAdapter(d.carrier, d.organizationId);
    const result = await adapter.createWaybill({ /* ... */ });
    trackingNo = result.trackingNo;
    estimatedCost = result.estimatedCost;
  }

  await db.$transaction(async (tx) => {
    await tx.delivery.update({
      where: { id: deliveryId },
      data: {
        status: 'ASSIGNED',
        driverId, vehicleId,
        trackingNo, shippingCost: estimatedCost
      }
    });
    await tx.eventOutbox.create({
      data: { eventType: 'DELIVERY_ASSIGNED', payload: { deliveryId, trackingNo }}
    });
  });
}
```

### EL-625. 실패 처리 (MUST)

API 호출 실패 (timeout / 4xx / 5xx):
- 4xx (입력 오류): Delivery 그대로 DRAFT, 운영자 알림
- 5xx / timeout: 자동 재시도 (exponential backoff, max 3회) → 그래도 실패 시 DRAFT 유지 + 알림
- DB 트랜잭션은 API 성공 후에만 커밋 (외부 API 가 트랜잭션에 포함 X — saga 패턴)

> ⚠️ API 가 운송장 발행한 후 DB 커밋 실패 → 외부 운송장 cancel 보상 트랜잭션 (Phase 1+ Saga).

---

## 3. 콜백 webhook (EL-630 ~ EL-649) — MUST

### EL-630. 보안 검증 (MUST)

각 carrier 의 webhook 서명 / IP 검증:
- HMAC 서명 검증 (대부분의 carrier)
- IP 화이트리스트 (carrier 발신 IP 범위)
- 토큰 검증 (URL path 또는 header)

```typescript
async function carrierCallbackHandler(req, res) {
  const carrier = req.params.carrier;
  if (!verifyCarrierSignature(carrier, req.headers, req.body)) {
    res.status(401);
    return;
  }
  const adapter = adapters[carrier];
  await adapter.handleCallback(req.body, req.headers);
  res.status(200);
}
```

### EL-635. 멱등 처리 (MUST)

`tracking_events (delivery_id, source, source_id) UNIQUE` (EL-310). 같은 carrier event_id 중복 방어.

```typescript
async handleCallback(payload, headers) {
  const events = parseCallback(payload);
  for (const e of events) {
    try {
      await db.trackingEvent.create({
        data: {
          deliveryId: e.deliveryId,
          eventType: mapStatusToEventType(e.status),
          eventAt: e.occurredAt,
          source: `carrier_${this.name}`,
          sourceId: e.carrierEventId,    // carrier 가 발신한 unique ID
          payload: e.raw
        }
      });

      // 상태 매핑 → delivery 전이 (DELIVERED / FAILED 등)
      if (e.status === 'DELIVERED') {
        await transitionDelivery(e.deliveryId, 'DELIVERED');
      }
    } catch (err) {
      if (isUniqueViolation(err)) continue;  // 멱등
      throw err;
    }
  }
}
```

### EL-640. 상태 매핑 (MUST)

각 carrier 의 상태 코드 → 표준 상태로 매핑:

| 표준 | CJ | 한진 | 우체국 | 롯데 |
|---|---|---|---|---|
| `IN_TRANSIT` | 81 / 82 | 80 / 81 | 49 / 50 | 11 / 12 |
| `OUT_FOR_DELIVERY` | 86 | 86 | 60 | 14 |
| `DELIVERED` | 91 | 91 | 70 | 41 |
| `FAILED` | 95 | 99 | 71 | 51 |

각 carrier 어댑터 안에 `mapStatusToEventType()` 메서드. 정확한 코드는 carrier 문서 참조.

---

## 4. 멀티 어댑터 라우팅 (EL-650 ~ EL-659)

### EL-650. carrier 선택 정책 (옵션)

자동 carrier 선택 — 비용 / SLA / 가용성:
- 단순: 조직 기본 carrier (`organizations.default_carrier`)
- 비용: 견적 비교 (`getQuote` 모든 활성 carrier → 최저)
- SLA: 시간 약속 가능한 carrier 만 후보

운영자 수동 선택 우선. 자동은 보조 (Phase 1+).

### EL-655. fallback (MUST)

주 carrier API 다운 → 대체 carrier:
- 운영자 알림 + 수동 결정 (안전)
- 자동 fallback 은 위험 (단가 / SLA 다름) — 옵션이라도 audit 필수

---

## 5. KR 표준 carrier 매트릭스 (EL-680 ~ EL-699)

### EL-680. 주요 carrier 정보 (참고)

| Carrier | API Base | Sandbox | 운송장 형식 | 콜백 방식 |
|---|---|---|---|---|
| CJ대한통운 (`cj`) | `api.cjlogistics.com` | 별도 | 12자리 숫자 | webhook (HMAC) |
| 한진택배 (`hanjin`) | `api.hanjin.co.kr` | 별도 | 12자리 숫자 | webhook |
| 우체국택배 (`korea_post`) | `epost.go.kr` (REST) | 일부 | 13자리 숫자 | polling 기반 |
| 롯데택배 (`lotte`) | `lotteglogis.com` | 별도 | 12자리 | webhook |

> 정확한 API URL / 인증 방법 / 콜백 형식은 각 carrier 의 개발자 가이드 참조 (시점에 따라 변경).

### EL-685. 운송장 형식 검증 (MUST)

```typescript
function validateTrackingNo(carrier: string, trackingNo: string): boolean {
  const patterns = {
    cj:           /^\d{12}$/,
    hanjin:       /^\d{12}$/,
    korea_post:   /^\d{13}$/,
    lotte:        /^\d{12}$/
  };
  return patterns[carrier]?.test(trackingNo) ?? false;
}
```

### EL-690. 운송약관 (KR)

화물자동차운수사업법 §5, 표준운송약관 — carrier 별 약관 동의 필수. 시스템에는 약관 버전 / 동의 시점 audit 만 보관 (실 약관 본문은 carrier 사이트).

---

## 6. 권한 / 감사 (EL-695 ~ EL-699)

### EL-695. 권한

| 작업 | L3 | L4 | Super |
|---|---|---|---|
| API 키 / 시크릿 조회 | ❌ | ❌ | ✅ |
| API 키 변경 | ❌ | ❌ | ✅ |
| 어댑터 토글 | ❌ | ✅ | ✅ |
| 운송장 발행 (carrier API) | ✅ (시스템 자동) | ✅ | ✅ |
| 콜백 강제 재처리 | ❌ | ✅ | ✅ |

### EL-697. 감사

| action | 시점 |
|---|---|
| `logistics.carrier.api_called` | API 호출 (요청 / 응답 시간 / 결과) |
| `logistics.carrier.callback_received` | webhook 수신 |
| `logistics.carrier.callback_signature_invalid` | 서명 검증 실패 (보안 알림) |
| `logistics.carrier.api_failed` | API 실패 (재시도 횟수) |
| `logistics.carrier.fallback_executed` | fallback 사용 |

---

## 7. 참조

- 게이트: `feature_flags.md` (`logistics.carrier_*`)
- delivery 전이: `delivery.md` § EL-040
- tracking 멱등: `tracking_pod.md` § EL-318
- 운임: `shipping_cost.md`
- 스키마: `../schemas/tables/logistics_carrier_configs.sql` (Phase 1+)
