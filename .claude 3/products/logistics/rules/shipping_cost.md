# 운임 / 배송료 (Shipping Cost)

> **ID 범위**: EL-400 ~ EL-499
> **주제**: 운임 단가표 (tariff), 배송별 운임 산정, 정산
> **상위**: `INDEX.md`

---

## TL;DR

- **tariff = 운임 단가표** — 무게 / 부피 / 거리 / 지역 / carrier 별 단가 매트릭스.
- **시점별 이력 보존 (MUST)** — 단가 변경 시 새 row. 과거 배송 정산 시점 단가 유지.
- **도서산간 추가요금 (KR)** — 별도 surcharge 룰. 우편번호 / 행정구역 기반.
- **배송별 운임 = 즉시 계산** — Delivery 생성 시 산정 (UNIT_COST 와 유사 패턴).
- **carrier 별 운임 분리** — self / cj / hanjin / korea_post / lotte 별 단가표 분리.
- **정산 (Phase 1+)** — 월말 / 분기말 carrier 별 합계 → 매입 처리 (회계 모듈 연동).

핵심 ID: EL-410 (tariff 모델) / EL-420 (산정 로직) / EL-430 (도서산간) / EL-440 (정산)

---

## 1. tariff 모델 (EL-400 ~ EL-419)

### EL-410. 단가표 (MUST)

```sql
CREATE TABLE logistics_tariffs (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  carrier         VARCHAR(20) NOT NULL,           -- self / cj / hanjin / korea_post / lotte
  tariff_code     VARCHAR(50) NOT NULL,           -- 'STANDARD_5KG' / 'EXPRESS_REGION_A'

  -- 적용 조건
  weight_min_kg   NUMERIC(10, 3),                 -- inclusive
  weight_max_kg   NUMERIC(10, 3),                 -- inclusive
  volume_min_m3   NUMERIC(10, 3),
  volume_max_m3   NUMERIC(10, 3),
  region          VARCHAR(20),                    -- METROPOLITAN / RURAL / ISLAND
  delivery_type   VARCHAR(20),                    -- STANDARD / EXPRESS / SAME_DAY

  -- 단가
  base_price      NUMERIC(14, 0) NOT NULL,        -- KRW 정수
  per_km_price    NUMERIC(14, 0),                 -- 거리 기반 가산 (옵션)

  -- 시점
  effective_from  DATE NOT NULL,
  effective_to    DATE,

  notes           TEXT,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, carrier, tariff_code, effective_from)
);
```

### EL-415. 단가 변경 = 새 row (MUST)

`payroll_compensation_settings` (EP-205), `inventory_task_definitions` (EI-812) 와 동일 패턴:
- 단가 변경 시 기존 row `effective_to` 갱신 + 새 row INSERT
- 과거 배송 정산은 당시 단가로 보존
- UPDATE 만으로 단가 변경 금지

---

## 2. 운임 산정 (EL-420 ~ EL-429)

### EL-420. 산정 알고리즘 (MUST)

```typescript
async function calculateShippingCost(delivery: Delivery): Promise<number> {
  const lines = await db.deliveryLine.findMany({
    where: { deliveryId: delivery.id },
    include: { item: true }
  });

  // v0.2: UOM 변환 (EI-024 정합) + NULL 처리
  let totalWeight = 0;
  let totalVolume = 0;
  let hasWeightData = true;       // 모든 라인이 weight 데이터 있는가
  let hasVolumeData = true;

  for (const l of lines) {
    if (l.item.weight && l.item.weightUom) {
      totalWeight += convertWeight(l.item.weight, l.item.weightUom, 'kg') * Number(l.qty);
    } else {
      hasWeightData = false;
    }
    if (l.item.volume && l.item.volumeUom) {
      totalVolume += convertVolume(l.item.volume, l.item.volumeUom, 'm3') * Number(l.qty);
    } else {
      hasVolumeData = false;
    }
  }

  const region = await classifyRegion(delivery.recipientPostal);
  const dispatchDate = delivery.scheduledAt ?? new Date();

  // 1. 시점 단가 조회 (가장 좁은 조건 우선)
  // NULL 데이터: 해당 차원 (weight / volume) 매칭 조건 무시
  const tariff = await db.tariff.findFirst({
    where: {
      carrier: delivery.carrier,
      effectiveFrom: { lte: dispatchDate },
      OR: [{ effectiveTo: null }, { effectiveTo: { gte: dispatchDate }}],
      AND: [
        // weight 조건 — 데이터 있을 때만 적용
        hasWeightData
          ? { OR: [{ weightMaxKg: { gte: totalWeight }}, { weightMaxKg: null }]}
          : { weightMaxKg: null },     // 무게 무관 단가만
        { OR: [{ region }, { region: null }]},
        { OR: [{ deliveryType: delivery.deliveryType }, { deliveryType: null }]}
      ]
    },
    orderBy: [
      { region: 'asc' },
      { weightMaxKg: 'asc' }
    ]
  });
  if (!tariff) {
    if (!hasWeightData) {
      logger.warn(`운임 산정: 일부 item 의 weight 데이터 부재 — 무게 무관 단가만 매칭 시도, 실패`);
    }
    throw new TariffNotFoundError();
  }

  let cost = Number(tariff.basePrice);
  if (tariff.perKmPrice && delivery.distanceKm) {
    cost += Number(tariff.perKmPrice) * Number(delivery.distanceKm);
  }

  // 2. 도서산간 surcharge (EL-430)
  cost += await getRegionSurcharge(delivery.recipientPostal, dispatchDate);

  return Math.round(cost);  // KRW 정수
}
```

### EL-422. NULL 처리 정책 (MUST, v0.2)

`item.weight` / `item.volume` NULL 시 운임 정확도 저하:

| 케이스 | 처리 |
|---|---|
| 모든 라인 weight 있음 + tariff 매칭 성공 | 정상 정확 운임 |
| 일부 라인 weight NULL | 무게 무관 (`weight_max_kg IS NULL`) tariff 만 매칭 시도 + warn 로그 |
| 모든 라인 weight NULL | 동일 — 무게 무관 tariff 만 |
| 무게 무관 tariff 도 없음 | `TariffNotFoundError` + 운영 알림 (`logistics.cost.tariff_not_found`) |
| 일부 라인 volume NULL | 운영 운임 정확도 저하 가능, base_price 만 적용 시 안전 |

운영 권고:
- 운영자에게 "weight 누락 item 백필" 우선순위 제안
- Super 화면에서 "운임 산정 시 NULL 비율" KPI 모니터링

### EL-425. delivery 에 단가 보존 (MUST)

```sql
ALTER TABLE logistics_deliveries
  ADD COLUMN shipping_cost NUMERIC(14, 0),
  ADD COLUMN tariff_id     UUID,                  -- 적용된 tariff (이력 추적)
  ADD COLUMN cost_breakdown JSONB;                -- { base, per_km, surcharge, ... }
```

산정 결과는 delivery 에 즉시 확정값 저장 (EI-825 / EP-102 와 동일 원칙).

---

## 3. 도서산간 (KR) (EL-430 ~ EL-439)

### EL-430. surcharge 룰 (MUST, KR)

도서산간 = 제주 / 울릉도 / 일부 도서 / 산간. 우편번호 또는 행정구역 매핑.

```sql
CREATE TABLE logistics_region_surcharges (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  carrier         VARCHAR(20) NOT NULL,
  postal_pattern  VARCHAR(20) NOT NULL,           -- 우편번호 패턴 (정확 or prefix)
  region_label    VARCHAR(50) NOT NULL,           -- '제주' / '울릉도' / '도서' / '산간'
  surcharge       NUMERIC(14, 0) NOT NULL,        -- 가산 금액 (KRW)
  effective_from  DATE NOT NULL,
  effective_to    DATE,
  UNIQUE (organization_id, carrier, postal_pattern, effective_from)
);
```

### EL-435. 우편번호 매칭 (MUST)

한국 우편번호 5자리 (2015 신주소체계). 매칭 패턴:
- 정확: `'63000'` (제주 5자리 정확)
- prefix: `'63%'` (제주 전체)
- 행정구역 기반: 별도 매핑 테이블 (Phase 1+)

```typescript
async function getRegionSurcharge(postal, date) {
  if (!postal) return 0;
  const surcharges = await db.regionSurcharge.findMany({
    where: {
      effectiveFrom: { lte: date },
      OR: [{ effectiveTo: null }, { effectiveTo: { gte: date }}]
    }
  });
  let total = 0;
  for (const s of surcharges) {
    if (matchPostalPattern(postal, s.postalPattern)) {
      total += Number(s.surcharge);
    }
  }
  return total;
}
```

### EL-438. 표준 도서산간 KRW (참고)

| 지역 | 표준 가산 (carrier 평균) |
|---|---|
| 제주 | 3,000 ~ 5,000 KRW |
| 울릉도 | 5,000 ~ 8,000 KRW |
| 기타 도서 | 3,000 ~ 6,000 KRW |
| 산간 | 1,000 ~ 3,000 KRW |

> 단가는 carrier / 시점 / 무게에 따라 다름. 실 운영은 carrier API 또는 단가표 갱신.

---

## 4. 정산 (Phase 1+) (EL-440 ~ EL-449)

### EL-440. carrier 별 월간 합계 (MUST, Phase 1+)

```sql
CREATE TABLE logistics_settlements (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  carrier         VARCHAR(20) NOT NULL,
  period_year     SMALLINT NOT NULL,
  period_month    SMALLINT NOT NULL,
  total_deliveries INTEGER NOT NULL,
  total_amount    NUMERIC(14, 0) NOT NULL,
  status          VARCHAR(20) NOT NULL,           -- DRAFT / FINALIZED / PAID / DISPUTED
  finalized_at    TIMESTAMPTZ,
  paid_at         TIMESTAMPTZ,
  UNIQUE (organization_id, carrier, period_year, period_month)
);
```

월말 cron — 해당 월 DELIVERED 상태 deliveries 의 carrier 별 shipping_cost 합계.

### EL-445. carrier 청구서 vs 시스템 합계 (MUST, Phase 2+)

외부 carrier 가 발송하는 청구서 vs 시스템 산출 합계 — 차이 비교:
- 일치 → 정산 승인 (FINALIZED → PAID)
- 차이 → DISPUTED + 운영자 검토

---

## 5. 권한 / 감사 (EL-480 ~ EL-499)

### EL-480. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| tariff 조회 | ❌ | ✅ | ✅ | ✅ |
| tariff 신규 등록 | ❌ | ✅ | ✅ | ⚠️ |
| tariff 단가 변경 (새 row) | ❌ | ✅ | ✅ | ⚠️ |
| 도서산간 surcharge 변경 | ❌ | ❌ | ✅ | ⚠️ |
| 정산 승인 (FINALIZED) | ❌ | ❌ | ✅ | ⚠️ |
| DISPUTED 처리 | ❌ | ❌ | ✅ | ⚠️ |

### EL-490. 감사

| action | 시점 |
|---|---|
| `logistics.tariff.created` | 단가 신규 |
| `logistics.tariff.price_changed` | 단가 변경 (새 row) |
| `logistics.delivery.cost_calculated` | 운임 산정 |
| `logistics.settlement.finalized` | 정산 승인 |
| `logistics.settlement.disputed` | 차이 발견 |

---

## 6. 참조

- 게이트: `feature_flags.md` (carrier 어댑터별)
- delivery: `delivery.md`
- carrier 외부 API: `carrier.md` (EL-600~)
- 인벤토리 item.weight / volume: `../../inventory/rules/item_master.md`
- 스키마: `../schemas/tables/logistics_tariffs.sql`, `logistics_region_surcharges.sql`
