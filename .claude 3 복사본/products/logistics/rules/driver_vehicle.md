# 기사 / 차량 (Driver / Vehicle)

> **ID 범위**: EL-100 ~ EL-199
> **주제**: 운전자 / 차량 마스터, 면허 / 보험 만료 알림, 적재 한도
> **상위**: `INDEX.md`

---

## TL;DR

- **driver = users 와 1:N 관계** — payroll 의 사용자가 곧 driver. logistics_drivers 는 운전자 특유 정보 (면허 / 차량 / 자격) 만 추가.
- **vehicle = 차량 마스터** — 적재 중량 / 부피, 보험 만료, 차량 종류.
- **면허 / 보험 만료 차단 (MUST)** — 만료된 driver / vehicle 은 ASSIGNED 전이 거부.
- **적재 한도 검증 (MUST)** — Delivery 합계 weight / volume ≤ vehicle capacity.
- **driver-vehicle 매핑** — 1:N 가능 (한 기사가 여러 차량 운전 가능). delivery 시점에 결정.
- **기사 위치 = PII** — `logistics.driver_location_logging` 토글 + 동의 시만.

핵심 ID: EL-110 (driver) / EL-130 (vehicle) / EL-150 (만료 차단) / EL-160 (적재 검증)

---

## 1. driver 모델 (EL-100 ~ EL-129)

### EL-110. 핵심 필드 (MUST)

```sql
CREATE TABLE logistics_drivers (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  user_id         UUID NOT NULL,                  -- users 와 1:1
  driver_code     VARCHAR(20) NOT NULL,           -- 사내 코드
  license_no      VARCHAR(30) NOT NULL,           -- 운전면허
  license_type    VARCHAR(20) NOT NULL,           -- 1종보통 / 1종대형 / 2종 / 특수
  license_expires_at DATE NOT NULL,
  hazmat_cert     BOOLEAN DEFAULT FALSE,          -- 위험물 자격
  hazmat_expires_at DATE,
  status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE / SUSPENDED / TERMINATED
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, driver_code),
  UNIQUE (organization_id, user_id)
);
```

### EL-115. user 와 정합 (MUST)

- driver 등록 시 user_id NOT NULL
- user 가 비활성 / 삭제 → driver.status = TERMINATED 자동
- payroll 의 compensation_settings 와 별개 (기사 인건비는 payroll 도메인)

### EL-120. license_type 적용 (MUST)

차량 종류별 면허 매트릭스:

| vehicle_type | 필요 면허 |
|---|---|
| 승용 (오토바이 제외) | 1종 또는 2종 보통 |
| 1톤 트럭 | 1종 보통 |
| 5톤 트럭 | 1종 대형 |
| 위험물 운반 | 1종 + 위험물 자격 |
| 오토바이 | 2종 소형 + 별도 |

배차 시점 자동 검증 (EL-160):
```typescript
function validateLicenseForVehicle(driver, vehicle) {
  const required = REQUIRED_LICENSE[vehicle.vehicleType];
  if (!required.includes(driver.licenseType)) {
    throw new InsufficientLicenseError();
  }
}
```

---

## 2. vehicle 모델 (EL-130 ~ EL-149)

### EL-130. 핵심 필드 (MUST)

```sql
CREATE TABLE logistics_vehicles (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  vehicle_no      VARCHAR(20) NOT NULL,           -- 차량번호 '12가1234'
  vehicle_type    VARCHAR(20) NOT NULL,           -- TRUCK_1T / TRUCK_5T / VAN / MOTORCYCLE / etc.
  capacity_weight NUMERIC(10, 2),                 -- kg
  capacity_volume NUMERIC(10, 2),                 -- m3
  -- 보험 (KR 자동차손해배상보장법)
  insurance_no    VARCHAR(50),
  insurance_expires_at DATE,
  -- 검사 (자동차관리법)
  inspection_expires_at DATE,
  -- 상태
  status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE / MAINTENANCE / RETIRED
  meta            JSONB,                          -- 연료타입 / 등록일 / 주행거리
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, vehicle_no)
);
```

### EL-135. 차량번호 형식 (KR)

`^[0-9]{2,3}[가-힣][0-9]{4}$` — 한국 차량번호 표준. 영업용 / 자가용 구분 없이 동일 패턴.

```sql
CHECK (vehicle_no ~ '^[0-9]{2,3}[가-힣][0-9]{4}$')
```

### EL-140. 적재 한도 단위 (MUST)

- weight = kg (NUMERIC(10, 2))
- volume = m3 (NUMERIC(10, 2))

Delivery 의 적재 합계 (delivery_lines 의 item.weight / item.volume × qty 합계) ≤ vehicle capacity. 없는 데이터는 검증 skip.

---

## 3. 만료 차단 / 알림 (EL-150 ~ EL-159) — MUST

### EL-150. 배차 시 만료 검증 (MUST)

```typescript
async function validateForAssignment(driverId, vehicleId, scheduledAt) {
  const driver = await db.driver.findUnique({ where: { id: driverId }});
  const vehicle = await db.vehicle.findUnique({ where: { id: vehicleId }});
  const assignmentDate = scheduledAt ?? new Date();

  // driver 면허
  if (driver.licenseExpiresAt < assignmentDate) {
    throw new ExpiredLicenseError(driver.driverCode);
  }
  // vehicle 보험
  if (vehicle.insuranceExpiresAt && vehicle.insuranceExpiresAt < assignmentDate) {
    throw new ExpiredInsuranceError(vehicle.vehicleNo);
  }
  // vehicle 검사
  if (vehicle.inspectionExpiresAt && vehicle.inspectionExpiresAt < assignmentDate) {
    throw new ExpiredInspectionError(vehicle.vehicleNo);
  }
  // 면허 / 차량 매트릭스
  validateLicenseForVehicle(driver, vehicle);
}
```

### EL-155. 만료 임박 알림 (MUST)

매일 cron — 30/14/7/1일 전 알림:
- driver: license_expires_at, hazmat_expires_at
- vehicle: insurance_expires_at, inspection_expires_at

```typescript
const upcoming = await db.$queryRaw`
  SELECT 'driver_license' as kind, id, license_expires_at as expires_at FROM logistics_drivers
   WHERE status = 'ACTIVE' AND license_expires_at - CURRENT_DATE IN (1, 7, 14, 30)
  UNION ALL
  SELECT 'vehicle_insurance', id, insurance_expires_at FROM logistics_vehicles
   WHERE status = 'ACTIVE' AND insurance_expires_at - CURRENT_DATE IN (1, 7, 14, 30)
`;
for (const u of upcoming) {
  await sendAlert(`${u.kind} 만료 ${differenceInDays(u.expires_at, today)}일 전.`);
}
```

---

## 4. 적재 검증 (EL-160 ~ EL-169)

### EL-160. 배차 시 적재 합계 검증 (MUST, 데이터 있을 때)

v0.2 정합 — inventory_items 의 `weight` / `weight_uom` / `volume` / `volume_uom` (EI-024) 활용. 단위 변환 + NULL 처리 명시:

```typescript
async function validateCapacity(deliveryIds, vehicle) {
  const lines = await db.deliveryLine.findMany({
    where: { deliveryId: { in: deliveryIds }},
    include: { item: true }
  });

  let totalWeightKg = 0;
  let totalVolumeM3 = 0;
  let skippedWeightItems = 0;     // weight 데이터 없는 라인 수
  let skippedVolumeItems = 0;

  for (const l of lines) {
    if (l.item.weight && l.item.weightUom) {
      // UOM 변환 → kg 통일
      totalWeightKg += convertWeight(l.item.weight, l.item.weightUom, 'kg') * Number(l.qty);
    } else {
      skippedWeightItems += 1;
    }
    if (l.item.volume && l.item.volumeUom) {
      totalVolumeM3 += convertVolume(l.item.volume, l.item.volumeUom, 'm3') * Number(l.qty);
    } else {
      skippedVolumeItems += 1;
    }
  }

  // NULL 처리: skip + 경고 (검증 자체는 통과)
  if (skippedWeightItems > 0) {
    logger.warn(`적재 검증 skip: weight 데이터 없는 item ${skippedWeightItems}개 (검증 통과 처리)`);
  }
  if (skippedVolumeItems > 0) {
    logger.warn(`적재 검증 skip: volume 데이터 없는 item ${skippedVolumeItems}개`);
  }

  if (vehicle.capacityWeight && totalWeightKg > Number(vehicle.capacityWeight)) {
    throw new CapacityExceededError(`적재 ${totalWeightKg.toFixed(2)}kg > 한도 ${vehicle.capacityWeight}kg`);
  }
  if (vehicle.capacityVolume && totalVolumeM3 > Number(vehicle.capacityVolume)) {
    throw new CapacityExceededError(`적재 ${totalVolumeM3.toFixed(3)}m³ > 한도 ${vehicle.capacityVolume}m³`);
  }
}
```

### EL-162. 단위 변환 표준 (MUST, v0.2)

`convertWeight(value, fromUom, toUom)` / `convertVolume(value, fromUom, toUom)` 헬퍼:

| 무게 변환 (→ kg 기준) | 부피 변환 (→ m³ 기준) |
|---|---|
| `kg` → ×1 | `m3` → ×1 |
| `g` → ÷1000 | `l` → ÷1000 |
| `lb` → ×0.453592 | `ml` → ÷1_000_000 |
| `oz` → ÷35.274 | `cm3` → ÷1_000_000 |
| `t` → ×1000 |  |

구현: `business/logistics/services/uom-converter.ts` (Phase 1+).

### EL-165. NULL 처리 정책 (MUST, v0.2)

`item.weight` / `item.volume` NULL 케이스:
- 검증 skip (오류 X) + warn 로그 (운영 경고)
- vehicle.capacity 가 NULL 이면 해당 차원 검증 skip (양쪽 NULL 안전)
- Super 화면에서 "검증 skip 비율" 모니터링 — 일정 임계값 초과 시 데이터 백필 권장

> ⚠️ Phase 0 — 일부 item 에만 weight / volume 데이터. 점진적 백필 + 비율 모니터링.

---

## 5. 권한 / 감사 (EL-180 ~ EL-199)

### EL-180. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| driver 조회 | ✅ | ✅ | ✅ | ✅ |
| driver 등록 / 수정 | ❌ | ✅ | ✅ | ⚠️ |
| 면허 정보 수정 | ❌ | ❌ | ✅ | ⚠️ |
| vehicle 등록 / 수정 | ❌ | ✅ | ✅ | ⚠️ |
| 보험 / 검사 정보 수정 | ❌ | ❌ | ✅ | ⚠️ |
| 만료된 항목 강제 배차 | ❌ | ❌ | ⚠️ (audit) | ✅ |

### EL-190. 감사

| action | 시점 |
|---|---|
| `logistics.driver.created` | 신규 등록 |
| `logistics.driver.license_renewed` | 면허 갱신 |
| `logistics.driver.suspended` | 정지 |
| `logistics.vehicle.created` | 신규 등록 |
| `logistics.vehicle.insurance_renewed` | 보험 갱신 |
| `logistics.assignment.expired_license_blocked` | 만료 면허 배차 차단 |
| `logistics.assignment.capacity_exceeded` | 적재 한도 초과 |

---

## 6. 참조

- delivery 배차: `delivery.md` § EL-020
- 추적 / 위치: `tracking_pod.md`
- 권한 매트릭스 상위: `../../../rules/permissions.md`
- 스키마: `../schemas/tables/logistics_drivers.sql`, `logistics_vehicles.sql`
