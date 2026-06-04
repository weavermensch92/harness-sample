# 추적 / 수령확인 (Tracking & POD)

> **ID 범위**: EL-300 ~ EL-399
> **주제**: 실시간 위치 추적, POD (Proof of Delivery — 사인 / 사진 / 실명확인)
> **상위**: `INDEX.md`
> **게이트**: `logistics.real_time_tracking`, `logistics.pod_signature`, `logistics.pod_photo`, `logistics.pod_id_verification`
> **기준법**: 개인정보보호법 §15, §29

---

## TL;DR

- **Tracking events** = 시간순 위치 / 상태 이벤트 append-only. 모바일 앱 / GPS / carrier API 가 발신.
- **POD = 수령 증빙** — 사인 (서명 이미지) / 사진 (수령자 + 패키지) / 실명확인 (의약품 / 주류).
- **POD 등록이 DELIVERED 전이 트리거** — POD 없이 DELIVERED 전이 거부.
- **PII 처리 — 위치 / 사진 / 사인 모두 PII**. 마스킹 / 보존 기간 / 암호화 강제.
- **실명확인 (KR)** — 의약품 / 주류 / 청소년 유해물품은 의무. 신분증 사진 또는 본인 인증 (휴대폰).
- **수령자 변경** — 수령자 본인 부재 시 위임 수령 가능. 수령인 정보 별도 기록.
- **위치 정보 보존**: 운전자 30일 / 배송 진행 중 위치 5년 (전자상거래법).

핵심 ID: EL-310 (이벤트) / EL-320 (POD 모델) / EL-330 (DELIVERED 전이) / EL-340 (실명확인 KR) / EL-350 (PII)

---

## 1. tracking_events (EL-300 ~ EL-319)

### EL-310. 모델 (MUST)

```sql
CREATE TABLE logistics_tracking_events (
  id              UUID PRIMARY KEY,
  delivery_id     UUID NOT NULL,
  event_type      VARCHAR(30) NOT NULL,
  -- DISPATCHED / IN_TRANSIT_LOCATION / ARRIVED_AT_STOP / DELIVERY_ATTEMPT
  -- DELIVERED / FAILED / RETURNED / CARRIER_UPDATE
  event_at        TIMESTAMPTZ NOT NULL,
  source          VARCHAR(20) NOT NULL,                 -- driver_app / carrier_api / system
  source_id       VARCHAR(100),                          -- 외부 ID (멱등)
  -- 위치 (선택, PII)
  lat             NUMERIC(10, 7),
  lng             NUMERIC(10, 7),
  -- 메타
  payload         JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (delivery_id, source, source_id)
);
```

### EL-312. append-only (MUST)

UPDATE / DELETE 금지. 정정 시 새 event 추가.

### EL-315. 빈도 제어 (SHOULD)

운전자 앱이 GPS 좌표를 너무 자주 업로드하면 DB 폭증:
- 1분 단위 그라뉼래리티 (분 이하 절삭)
- 같은 위치 반복 (정차 중) 은 5분에 1회만 기록
- 배송 완료 후 5초 이상은 무시

### EL-318. 외부 carrier 콜백 (MUST, 멱등)

CJ / 한진 등 외부 carrier 의 트래킹 webhook:
```typescript
async function handleCarrierTrackingCallback(event) {
  // ProcessedEvent + UNIQUE 2중 (같은 carrier event_id 중복 방어)
  await db.$transaction(async (tx) => {
    try {
      await tx.trackingEvent.create({
        data: {
          deliveryId: event.deliveryId,
          source: `carrier_${event.carrier}`,
          sourceId: event.carrierEventId,  // 멱등 키
          // ...
        }
      });
    } catch (e) {
      if (isUniqueViolation(e)) return;
      throw e;
    }
  });
}
```

---

## 2. POD 모델 (EL-320 ~ EL-339)

### EL-320. 핵심 필드 (MUST)

```sql
CREATE TABLE logistics_pods (
  id              UUID PRIMARY KEY,
  delivery_id     UUID NOT NULL,                  -- 1:1 (UNIQUE)

  -- 수령자 (본인 / 위임)
  recipient_kind  VARCHAR(20) NOT NULL,           -- SELF / DELEGATE / DOORSTEP / SECURITY
  delegate_name   VARCHAR(100),                   -- 위임 시 수령인 (이름 마스킹)
  delegate_relation VARCHAR(50),                  -- 위임 관계

  -- POD 증빙
  signature_url   TEXT,                            -- 사인 이미지 URL (signed, TTL)
  photo_urls      TEXT[],                          -- 사진 URLs
  id_verified     BOOLEAN DEFAULT FALSE,           -- 실명확인 완료
  id_method       VARCHAR(30),                    -- 'mobile_oauth' / 'driver_license_photo' / 'manual'
  id_meta         JSONB,                          -- 검증 결과 (해시 / 마스킹 ID)

  -- 시간 / 위치
  completed_at    TIMESTAMPTZ NOT NULL,
  lat             NUMERIC(10, 7),
  lng             NUMERIC(10, 7),

  notes           TEXT,
  created_by      UUID NOT NULL,                  -- driver
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (delivery_id)
);
```

### EL-325. POD 종류별 요구사항 (MUST)

조직 / 카테고리별 POD 요구 매트릭스:

| 카테고리 | 사인 | 사진 | 실명확인 |
|---|---|---|---|
| 일반 | 옵션 | 옵션 | ❌ |
| 고가 (>50만원) | 필수 | 필수 | ❌ |
| 의약품 | 필수 | 필수 | **필수** |
| 주류 / 담배 | ❌ | 필수 | **필수** (성인) |
| 청소년 유해물품 | ❌ | 필수 | **필수** (성인) |
| 우편물 (등기) | 필수 | 옵션 | ❌ |
| B2B (창고 입고) | 필수 (담당자 사인) | 필수 | ❌ |

토글로 운영:
- `logistics.pod_signature` (기본 ON)
- `logistics.pod_photo` (기본 ON)
- `logistics.pod_id_verification` (기본 OFF — 약국 / 주류 사업장만 ON)

### EL-328. POD 누락 정책 (MUST)

POD 등록 없이 DELIVERED 전이 시도 → 거부 (필수 항목 누락 시).

```typescript
async function validatePodForCompletion(delivery, pod) {
  const requirements = await getPodRequirements(orgId, delivery.deliveryType);
  if (requirements.signature && !pod.signatureUrl) throw new MissingPodError('서명 누락');
  if (requirements.photo && (!pod.photoUrls || pod.photoUrls.length === 0))
    throw new MissingPodError('사진 누락');
  if (requirements.idVerification && !pod.idVerified)
    throw new MissingPodError('실명확인 누락');
}
```

---

## 3. DELIVERED 전이 (EL-330 ~ EL-339)

### EL-330. 전이 트랜잭션 (MUST)

```typescript
async function completeDelivery(deliveryId, podData, driver) {
  await db.$transaction(async (tx) => {
    const d = await tx.delivery.findUnique({ where: { id: deliveryId }});
    if (d.status !== 'IN_TRANSIT') throw new InvalidTransitionError();

    // 1. POD INSERT
    await validatePodForCompletion(d, podData);
    const pod = await tx.pod.create({ data: { ...podData, deliveryId, createdBy: driver.id }});

    // 2. tracking event INSERT
    await tx.trackingEvent.create({
      data: { deliveryId, eventType: 'DELIVERED', eventAt: pod.completedAt, source: 'driver_app' }
    });

    // 3. delivery 상태 전이
    await tx.delivery.update({
      where: { id: deliveryId },
      data: { status: 'DELIVERED', completedAt: pod.completedAt }
    });

    // 4. outbox event
    await tx.eventOutbox.create({
      data: {
        eventType: 'DELIVERY_COMPLETED',
        payload: { deliveryId, podId: pod.id, driverId: driver.id, completedAt: pod.completedAt }
      }
    });
  });
}
```

### EL-335. payroll WorkLog 트리거 (MUST)

`DELIVERY_COMPLETED` → payroll 모듈 핸들러:
- WorkLog INSERT (source_type='DELIVERY', source_id=deliveryId, amount=기사 인건비)
- amount 산출 = 기사 compensation_settings 기반 (per_delivery / per_distance / per_time)
- payroll 의 piecework / hourly 등 scheme 에 따라 다름

상세: `../../payroll/rules/work_log.md` EP-100~.

---

## 4. 실명확인 (KR) (EL-340 ~ EL-349) — 토글 ON 시 MUST

### EL-340. 적용 카테고리 (KR)

| 품목 | 근거 |
|---|---|
| 의약품 | 약사법 §44 (전문의약품 본인 수령) |
| 주류 (성인) | 청소년보호법 §28 |
| 담배 | 청소년보호법 |
| 19금 출판물 / 영상 | 청소년보호법 |
| 농약 / 일부 화학물품 | 농약관리법, 화학물질관리법 |

### EL-345. 검증 방법 (MUST, 우선순위)

1. **모바일 본인인증** (OAuth 인증서 / 통신사 인증) — 가장 안전
2. **신분증 촬영** — 사진 보관 (마스킹 권장 — 주민번호 뒷자리 필요시 hash)
3. **수동 (현장 운영자 확인)** — 자율점검 시 가능, 분쟁 시 약함

### EL-348. 보관 의무 / 마스킹 (MUST)

- 신분증 사진 = PII. 보관 기간 5년 (전자상거래법). 5년 후 자동 삭제.
- 주민번호 뒷자리는 SHA-256 해시만 보관 (원본 X)
- 사진은 일부 마스킹 (얼굴 외 정보 가림)

---

## 5. PII 보호 (EL-350 ~ EL-369) — MUST, KR

### EL-350. 위치 정보

- 운전자 위치: `logistics.driver_location_logging` ON + 동의 필수. 보존 30일.
- 배송 위치 이벤트 (delivery 진행): 5년 보존 (전자상거래법).
- 좌표 정밀도: 7자리 (소수점) — 약 1cm. 너무 정확. 5자리 (1m) 또는 4자리 (10m) 권장.

### EL-355. 사진 / 사인 보관 (MUST)

- S3 / GCS / Supabase Storage 등 외부 저장. 암호화 (server-side encryption).
- 접근 = signed URL + TTL (15분).
- L1 / L2 / L3 권한별 접근 제한.

### EL-360. 마스킹 표시 (MUST)

UI 표시 시:
- 수령자 이름: "홍**" (본인 외 모든 권한)
- 사진: 썸네일은 흐리게, 클릭 시 권한 검증 후 풀 화면
- 사인: 썸네일은 일부만, 풀 보기는 권한 필요

### EL-365. 동의 / 거부 (MUST, opt-out)

수령자가 GPS / 사진 거부 시:
- 사인만 받거나 (대체)
- 부재 시 안전한 장소에 두고 사진 (DOORSTEP) — 단, 수령자 사전 동의 필요
- 거부 이력 audit 기록

---

## 6. 권한 / 감사 (EL-380 ~ EL-399)

### EL-380. 권한

| 작업 | L1 | L2 (기사) | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 배송 추적 (수령자) | ✅ (본인) | — | — | — | — |
| tracking 이벤트 입력 (driver) | ❌ | ✅ (본인 배송) | ✅ | ✅ | ⚠️ |
| POD 등록 (driver) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| POD 조회 (마스킹) | ❌ | ✅ (본인) | ✅ | ✅ | ✅ |
| POD 조회 (풀, PII) | ❌ | ❌ | ⚠️ | ✅ | ✅ |
| 사진 / 사인 다운로드 | ❌ | ✅ (본인) | ⚠️ | ✅ | ✅ |
| 실명확인 데이터 조회 | ❌ | ❌ | ❌ | ✅ | ✅ |

### EL-390. 감사

| action | 시점 |
|---|---|
| `logistics.tracking.event_recorded` | 이벤트 INSERT |
| `logistics.pod.created` | POD 등록 |
| `logistics.pod.id_verified` | 실명확인 완료 |
| `logistics.pod.unmasked` | 풀 PII 조회 |
| `logistics.pod.photo_downloaded` | 사진 다운로드 |
| `logistics.location.consent_changed` | 위치 동의 변경 |

---

## 7. 참조

- 게이트: `feature_flags.md` (`logistics.real_time_tracking` / `pod_signature` / `pod_photo` / `pod_id_verification`)
- delivery 전이: `delivery.md` § EL-020 / EL-040
- driver 권한: `driver_vehicle.md`
- payroll 정합: `../../payroll/rules/work_log.md` (EP-100)
- 스키마: `../schemas/tables/logistics_tracking_events.sql`, `logistics_pods.sql`
