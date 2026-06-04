# v0.2 Cross-module — 룰 보강 패치 (Patches)

> **상위**: `INDEX.md`
> **버전**: v0.2 (cross-module)
> **목적**: 마이그레이션 001~003 에 따른 4 모듈 룰 / 스키마 보강 사항 정리

각 패치는 **삭제 / 추가** 형식으로 명시 — 원본 파일에 적용. 적용은 별도 ⑥/⑦ 트랙에서 수행 (지금 단계는 변경 사항 정리).

---

## 1. inventory 모듈 보강

### 1.1 `inventory/rules/stock_movement.md` § EI-110

**기존** (예상):
```
| `source_type` | 의미 | source_id 형식 |
|---|---|---|
| `PURCHASE` | 매입 입고 | 'po:{purchase_order_id}' |
| `ORDER` | 주문 출고 | 'ord:{order_id}' |
| `DELIVERY` | 배송 출고 | 'dlv:{delivery_id}' |
| `MANUAL` | 수동 입력 | 'man:{user_id}:{ts}' |
| `COUNT_ADJUSTMENT` | 실사 조정 | 'cnt:{count_id}' |
| `REVERSAL` | 정정 (REVERSAL) | 'rev:{original_movement_id}' |
| `TRANSFER_INTERNAL` | 창고 간 이동 | 'tr:{paired_id}' |
| `EXPIRY_DISPOSAL` | 만료 폐기 | 'exp:{lot_id}' |
```

**추가**:
```
| `RETURN` | 반품 입고 (logistics 정합) | 'rtn:{return_request_id}:{return_line_id}' |
```

→ 반품 시 logistics 가 발행하는 IN movement. 원 lot_id 보존 — 회수 추적 가능.

### 1.2 `inventory/rules/item_master.md` 신규 룰 EI-024

```markdown
### EI-024. 물리 속성 (무게 / 부피 / 차원) (SHOULD)

logistics 적재 검증 (EL-160) / 운임 산정 (EL-420) 정합용. NULL 허용 — 데이터 없으면 검증 skip + 경고.

| 컬럼 | 타입 | 단위 | 비고 |
|---|---|---|---|
| `weight` | NUMERIC(10, 2) | weight_uom (`kg` 기본) | 단일 단위 무게 |
| `weight_uom` | VARCHAR(10) | — | kg / g / lb / oz / t |
| `volume` | NUMERIC(10, 2) | volume_uom (`m3` 기본) | 단일 단위 부피 |
| `volume_uom` | VARCHAR(10) | — | m3 / l / ml / cm3 |
| `dim_length_cm` | NUMERIC(10, 2) | cm | 가로 (운송 적재 모델링) |
| `dim_width_cm` | NUMERIC(10, 2) | cm | 세로 |
| `dim_height_cm` | NUMERIC(10, 2) | cm | 높이 |

검증:
- 양수 (NULL 허용)
- weight ↔ weight_uom 둘 다 있거나 둘 다 NULL (CHECK)
- volume ↔ volume_uom 동일

logistics 측 활용:
- 적재 한도 검증 (driver_vehicle.md EL-160) — vehicle.capacity_weight / volume 비교
- 운임 산정 (shipping_cost.md EL-420) — tariff 매칭

데이터 없을 때 — logistics 측 NULL 처리:
- weight NULL → 적재 검증 skip + 경고
- volume NULL → 적재 검증 skip + 경고
- 운임 산정 → 무게 / 부피 의존하지 않는 단가 사용 (base_price 만)
```

### 1.3 `inventory/rules/INDEX.md` ENUM 카탈로그 갱신

**기존** (8개 source):
```
PURCHASE / ORDER / DELIVERY / MANUAL / COUNT_ADJUSTMENT / REVERSAL / TRANSFER_INTERNAL / EXPIRY_DISPOSAL
```

**갱신** (9개 source):
```
PURCHASE / ORDER / DELIVERY / MANUAL / COUNT_ADJUSTMENT / REVERSAL / TRANSFER_INTERNAL / EXPIRY_DISPOSAL / RETURN
```

### 1.4 `inventory/schemas/INDEX.md` § 2 ENUM 갱신

```
| `movement_source` | PURCHASE / ORDER / DELIVERY / MANUAL / COUNT_ADJUSTMENT / REVERSAL / TRANSFER_INTERNAL / EXPIRY_DISPOSAL / **RETURN** | movements |
```

### 1.5 `inventory/schemas/tables/inventory_items.sql` 보강

```sql
-- (기존 컬럼 정의 후)

-- 물리 속성 (logistics 적재 / 운임 정합, EI-024)
weight        NUMERIC(10, 2),
weight_uom    VARCHAR(10),
volume        NUMERIC(10, 2),
volume_uom    VARCHAR(10),
dim_length_cm NUMERIC(10, 2),
dim_width_cm  NUMERIC(10, 2),
dim_height_cm NUMERIC(10, 2),

-- CHECK 제약 (기존 제약 후 추가)
CONSTRAINT ck_items_weight_positive CHECK (weight IS NULL OR weight > 0),
CONSTRAINT ck_items_volume_positive CHECK (volume IS NULL OR volume > 0),
CONSTRAINT ck_items_weight_pair CHECK ((weight IS NULL) = (weight_uom IS NULL)),
CONSTRAINT ck_items_volume_pair CHECK ((volume IS NULL) = (volume_uom IS NULL)),
CONSTRAINT ck_items_weight_uom CHECK (weight_uom IS NULL OR weight_uom IN ('kg','g','lb','oz','t')),
CONSTRAINT ck_items_volume_uom CHECK (volume_uom IS NULL OR volume_uom IN ('m3','l','ml','cm3')),
```

### 1.6 `inventory/CLAUDE.md` § 3 Phase 상태 갱신

```
### ✅ Phase 0 → v0.2 (cross-module 정합 완료)
- movement_source ENUM 에 RETURN 추가 (logistics 정합)
- inventory_items 에 weight / volume / dim_*_cm 컬럼 추가
```

### 1.7 `inventory/CLAUDE.md` § 12 다음 단계 진행

기존 체크박스에서 다음 항목 ✅ 처리:
- [x] `movement_source` ENUM 에 `RETURN` 추가 마이그레이션 (logistics 정합)
- [x] inventory_items 에 `weight` / `volume` 컬럼 추가 (logistics 적재 검증 정합)

---

## 2. logistics 모듈 보강

### 2.1 `logistics/rules/returns.md` § EL-550 검증

**기존 코드 예시** (EL-550 IN movement 생성):
```typescript
await createInventoryMovement(tx, {
  direction: 'IN',
  itemId: line.deliveryLine.itemId,
  warehouseId: r.targetWarehouseId,
  lotId: line.deliveryLine.lotId,
  qty: line.qty,
  sourceType: 'RETURN',                // ← v0.2 마이그레이션 후 사용 가능
  sourceId: `ret:${r.id}:${line.id}`
});
```

**보강** (코멘트 갱신):
```
> ✅ v0.2 마이그레이션 001 적용 후 sourceType='RETURN' 사용 가능.
> source_id 형식: `rtn:{return_request_id}:{return_line_id}` (inventory stock_movement EI-110 정합).
```

> 코멘트의 `ret:` 을 `rtn:` 으로 통일 (inventory 룰 표준 prefix 와 정합).

### 2.2 `logistics/rules/driver_vehicle.md` § EL-160 적재 검증

**기존**:
```typescript
const totalWeight = lines.reduce((s, l) =>
  s + (l.item.weight ? Number(l.item.weight) * Number(l.qty) : 0), 0);
```

**보강** — 단위 변환 명시:
```typescript
async function validateCapacity(deliveryIds, vehicle) {
  const lines = await db.deliveryLine.findMany({
    where: { deliveryId: { in: deliveryIds }},
    include: { item: true }
  });

  let totalWeightKg = 0;
  let totalVolumeM3 = 0;
  let skippedWeight = 0;
  let skippedVolume = 0;

  for (const l of lines) {
    if (l.item.weight && l.item.weightUom) {
      // 단위 변환 → kg 통일
      totalWeightKg += convertWeight(l.item.weight, l.item.weightUom, 'kg') * Number(l.qty);
    } else {
      skippedWeight += Number(l.qty);
    }
    if (l.item.volume && l.item.volumeUom) {
      totalVolumeM3 += convertVolume(l.item.volume, l.item.volumeUom, 'm3') * Number(l.qty);
    } else {
      skippedVolume += Number(l.qty);
    }
  }

  if (skippedWeight > 0) {
    logger.warn(`적재 검증 skip: weight 데이터 없는 item ${skippedWeight}개`);
  }
  if (skippedVolume > 0) {
    logger.warn(`적재 검증 skip: volume 데이터 없는 item ${skippedVolume}개`);
  }

  if (vehicle.capacityWeight && totalWeightKg > Number(vehicle.capacityWeight)) {
    throw new CapacityExceededError(`적재 ${totalWeightKg}kg > 한도 ${vehicle.capacityWeight}kg`);
  }
  if (vehicle.capacityVolume && totalVolumeM3 > Number(vehicle.capacityVolume)) {
    throw new CapacityExceededError(`적재 ${totalVolumeM3}m³ > 한도 ${vehicle.capacityVolume}m³`);
  }
}
```

> 핵심: 단위 변환 헬퍼 + NULL skip + 경고 로그 + 표준 단위 비교.

### 2.3 `logistics/rules/shipping_cost.md` § EL-420 보강

운임 산정 시 NULL 처리 명시:

```
> ⚠️ item.weight / volume NULL 시:
> - tariff 매칭에서 weight_min/max / volume_min/max 조건 무시
> - base_price 단가만 적용 (per_km_price 는 가능)
> - 운영 경고 (운임 정확도 저하 가능성)
```

### 2.4 `logistics/rules/delivery.md` § EL-045 영향 매트릭스 검증

**기존**:
```
| DELIVERED | `DELIVERY_COMPLETED` | **payroll: WorkLog (기사 인건비)** |
```

**보강** — 정확한 source 명시:
```
| DELIVERED | `DELIVERY_COMPLETED` | payroll: WorkLog INSERT (sourceType='DELIVERY', sourceId=deliveryId) |
```

✅ v0.2 마이그레이션 003 후 `work_log_source.DELIVERY` 사용 가능.

### 2.5 `logistics/CLAUDE.md` § 12 다음 단계

기존 체크박스에서 다음 항목 ✅ 처리:
- [x] inventory `movement_source` ENUM 에 `RETURN` 추가 (정합 마이그레이션)
- [x] inventory_items 의 `weight` / `volume` 컬럼 추가 (적재 검증 정합)

추가 항목 명시 (Phase 1 코드):
- [ ] `business/logistics/services/uom-converter.ts` — 무게 / 부피 단위 변환
- [ ] `business/logistics/handlers/return-received-handler.ts` — inventory RETURN movement 생성

---

## 3. payroll 모듈 보강

### 3.1 `payroll/rules/work_log.md` § EP-100 검증

**기존**:
```sql
source_type     work_log_source NOT NULL,
-- DELIVERY / MANUAL / ATTENDANCE / ADJUSTMENT
```

**보강** — v0.11 PIECEWORK 추가 + v0.2 DELIVERY 안전 추가 명시:
```sql
source_type     work_log_source NOT NULL,
-- ATTENDANCE / MANUAL / ADJUSTMENT / DELIVERY (v0.2 안전 추가) / PIECEWORK (v0.11 추가)
```

### 3.2 `payroll/rules/work_log.md` § EP-110 source_type 표 검증

**기존**:
```
| DELIVERY | Logistics 배송 완료 이벤트 | deliveryId | business/payroll/handlers/delivery-handler.ts |
```

**보강** — 핸들러 이름 정확화:
```
| DELIVERY | Logistics 배송 완료 (DELIVERY_COMPLETED 이벤트) | deliveryId (logistics_deliveries.id) | business/payroll/handlers/delivery-completed-handler.ts |
```

### 3.3 `payroll/rules/work_log.md` § EP-130 핸들러 패턴 검증

**기존 코드 예시** 정합 검증:
```typescript
async function handleDeliveryCompleted(event) {
  await db.$transaction(async (tx) => {
    // 멱등 가드
    const exists = await tx.processedEvent.findUnique({ where: { eventId: event.id }});
    if (exists) return;

    // WorkLog INSERT (멱등 자연 키 — userId + sourceType + sourceId)
    await tx.workLog.create({
      data: {
        userId: event.driverId,
        sourceType: 'DELIVERY',         // ← v0.2 마이그레이션 003 적용 후 활성
        sourceId: event.deliveryId,
        amount: await calculateDriverWage(event),  // compensation_settings 기반
        // ...
      }
    });
    await tx.processedEvent.create({ data: { eventId: event.id }});
  });
}
```

✅ 정합 OK 명시 + driver wage 계산 로직 반영.

### 3.4 `payroll/rules/INDEX.md` ENUM 카탈로그 갱신

**기존** (예상):
```
- `work_log_source`: ATTENDANCE / MANUAL / ADJUSTMENT / PIECEWORK (v0.11)
```

**갱신**:
```
- `work_log_source`: ATTENDANCE / MANUAL / ADJUSTMENT / DELIVERY / PIECEWORK
  - DELIVERY: v0.2 cross-module 마이그레이션으로 안전 추가
  - PIECEWORK: v0.11 추가
```

### 3.5 `payroll/CLAUDE.md` § 11 다음 단계

기존 체크박스에서 다음 항목 ✅ 처리:
- [x] payroll work_log_source 에 `DELIVERY` 값 추가 (v0.2 마이그레이션 003)

추가 항목:
- [ ] `business/payroll/handlers/delivery-completed-handler.ts` — 기사 인건비 자동 생성
- [ ] `business/payroll/services/driver-compensation.ts` — per_delivery / per_distance / per_time scheme

---

## 4. reports 모듈 보강

reports 모듈은 마이그레이션 001~003 의 직접 영향 X (자체 데이터 변경 없음). 다만:

### 4.1 `reports/rules/INDEX.md` § 5 KR 법정 보고서

`KR_LOGISTICS_RETURN_RATE` 보고서가 정확한 RETURN movement 데이터 활용 가능:

> **갱신**: v0.2 cross-module 적용 후 logistics return → inventory RETURN movement 가 정합. 반품률 계산 정확도 향상.

### 4.2 `reports/rules/report_generation.md` § ER-153 캐시 무효화

추가 이벤트 매핑:
```
| `inventory.movement.recorded` (sourceType='RETURN') | inventory + logistics | 반품률 + 재고 평가 캐시 invalidate |
```

---

## 5. 공통 룰 보강

### 5.1 `rules/integration.md` § 5.3 페이로드 표준

**MovementRecordedPayload 의 sourceType 예시 갱신**:
```typescript
sourceType: string;  // 'PURCHASE' / 'DELIVERY' / 'RETURN' / 'MANUAL' / ...
```

### 5.2 `rules/integration.md` § 4.2 시퀀스 다이어그램 검증

반품 시퀀스 4.2 — `IN movement (RETURN, lot 보존)` ← v0.2 적용 후 정합 확인.

### 5.3 `rules/database.md` § 7.3 ENUM 추가 예시

기존 예시:
```sql
ALTER TYPE movement_source ADD VALUE IF NOT EXISTS 'RETURN' AFTER 'EXPIRY_DISPOSAL';
```

→ **v0.2 마이그레이션 001 의 실 사례** 로 명시.

---

## 6. 적용 우선순위

### 6.1 즉시 (Phase 0 → 0.2)

- [ ] inventory: stock_movement.md § EI-110 (RETURN 추가)
- [ ] inventory: item_master.md (EI-024 신규)
- [ ] inventory: INDEX.md / schemas/INDEX.md ENUM 갱신
- [ ] logistics: returns.md prefix 통일 (`ret:` → `rtn:`)
- [ ] logistics: driver_vehicle.md / shipping_cost.md NULL 처리 보강
- [ ] payroll: work_log.md 정합 검증 (이미 정합 — 명시만)
- [ ] payroll: INDEX.md ENUM 갱신
- [ ] CLAUDE.md 5종 (4 모듈 + 통합) Phase 상태 / 다음 단계 갱신

### 6.2 Phase 1 코드 작업 시

- [ ] handler 구현 (return-received / delivery-completed / movement)
- [ ] uom-converter 헬퍼
- [ ] driver-compensation 서비스
- [ ] 단위 테스트 / 통합 테스트

---

## 7. 산출물

| 종류 | 위치 |
|---|---|
| SQL 마이그레이션 4개 | `migrations/v0.2-cross-module/00X_*.sql` |
| 마이그레이션 INDEX | `migrations/v0.2-cross-module/INDEX.md` |
| 룰 보강 패치 (이 문서) | `migrations/v0.2-cross-module/RULE_PATCHES.md` |
| 영향 받는 룰 / 스키마 (직접 패치는 별도 트랙) | 6.1 목록 |

---

## 8. 참조

- 마이그레이션: `./001_*.sql`, `./002_*.sql`, `./003_*.sql`, `./004_*.sql`
- 인덱스: `./INDEX.md`
- DB 규약 (ENUM 추가 / 안전 마이그레이션): `../../rules/database.md` § 7
- 영향 모듈 CLAUDE.md:
  - `../../products/inventory/CLAUDE.md`
  - `../../products/logistics/CLAUDE.md`
  - `../../products/payroll/CLAUDE.md`
- 4-모듈 통합: `../../products/CLAUDE.md`
