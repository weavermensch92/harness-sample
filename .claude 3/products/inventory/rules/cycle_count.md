# 재고 실사 (Cycle Count)

> **ID 범위**: EI-500 ~ EI-599
> **주제**: 정기 재고 실사, 차이 조정
> **상위**: `INDEX.md`
> **게이트 토글**: `inventory.cycle_count` (기본 ON)

---

## TL;DR

- **실사 = 물리 재고 카운트 → 시스템 잔고 비교 → 차이 조정 (ADJUSTMENT movement)**.
- **3가지 모드**: FULL (전수) / CYCLE (순환) / SPOT (특정 품목 / 위치).
- **카운트 진행 중인 location 은 FROZEN** — 입출고 차단 (EI-510).
- **차이 조정은 ADJUSTMENT movement 한 쌍 (계산값 / 실측값)**. UPDATE balance 직접 X.
- **2회 카운트 (재확인) 의무** — 한국 회계 감사 표준.
- **권한 분리** — 카운트 입력자 ≠ 차이 조정 승인자.

핵심 ID: EI-510 (락 / FROZEN) / EI-520 (카운트 입력) / EI-530 (차이 조정) / EI-540 (재확인 의무)

---

## 1. cycle_count 모델 (EI-500 ~ EI-509)

### EI-500. 핵심 필드 (MUST)

```sql
CREATE TABLE inventory_cycle_counts (
  id              UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  count_type      VARCHAR(20) NOT NULL,          -- FULL / CYCLE / SPOT
  status          VARCHAR(20) NOT NULL,          -- DRAFT / IN_PROGRESS / COUNTING / RECONCILING / COMPLETED / CANCELLED
  scheduled_at    TIMESTAMPTZ,
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  scope           JSONB,                         -- { categories: [...], items: [...], locations: [...] }
  count_round     SMALLINT NOT NULL DEFAULT 1,   -- 1차 / 2차 (EI-540)
  approved_by     UUID,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE inventory_count_lines (
  id              UUID PRIMARY KEY,
  cycle_count_id  UUID NOT NULL,
  item_id         UUID NOT NULL,
  warehouse_id    UUID NOT NULL,
  location_id     UUID,
  lot_id          UUID,
  expected_qty    NUMERIC(14, 4) NOT NULL,       -- 카운트 시작 시점 시스템 잔고 (스냅샷)
  counted_qty     NUMERIC(14, 4),                -- 실측값 (NULL = 미카운트)
  diff_qty        NUMERIC(14, 4) GENERATED ALWAYS AS (counted_qty - expected_qty) STORED,
  counted_by      UUID,
  counted_at      TIMESTAMPTZ,
  notes           TEXT,
  UNIQUE (cycle_count_id, item_id, warehouse_id, location_id, lot_id)
);
```

---

## 2. 실사 절차 (EI-510 ~ EI-519)

### EI-510. 락 / FROZEN (MUST)

실사 시작 (`status = COUNTING`) 시 대상 location 들 자동 FROZEN:
```typescript
await db.$transaction(async (tx) => {
  // 1. cycle_count.status = COUNTING
  await tx.inventoryCycleCount.update({ where: { id }, data: { status: 'COUNTING', startedAt: new Date() }});

  // 2. expected_qty 스냅샷 (count_lines 생성)
  const balances = await getBalancesInScope(tx, scope);
  for (const b of balances) {
    await tx.inventoryCountLine.create({
      data: { cycleCountId: id, itemId: b.itemId, ..., expectedQty: b.qty }
    });
  }

  // 3. 대상 location FROZEN
  await tx.inventoryLocation.updateMany({
    where: { id: { in: locationIds }},
    data: { status: 'FROZEN' }
  });
});
```

### EI-512. 입출고 차단 (MUST)

FROZEN location 의 movement INSERT 거부 — `warehouse.md` EI-430 동작.

긴급 출고가 필요한 경우 — L4 명시 승인 + audit (실사 무효화 위험).

### EI-515. 카운트 완료 / 락 해제 (MUST)

모든 count_lines 의 counted_qty 입력 완료 → `status = RECONCILING`. 차이 조정 완료 → `status = COMPLETED` + location FROZEN 해제.

---

## 3. 카운트 입력 (EI-520 ~ EI-529)

### EI-520. 입력 방법 (SHOULD)

- **모바일 앱** (바코드 스캔 + qty 입력) — 권장
- **웹 UI** (목록 + 폼)
- **CSV 업로드** (대량)

### EI-525. 입력 권한 (MUST)

- L2 가능 (현장 작업자)
- 같은 라인 두 번 입력 시: 마지막 값 유지 + 이전 값 audit (덮어쓰기 시 알림)

### EI-528. lot 단위 카운트 (MUST, lot 추적 시)

LOT 추적 품목은 lot 단위로 별도 라인. 합산 후 입력 X.

---

## 4. 차이 조정 (EI-530 ~ EI-539)

### EI-530. 차이 발견 (MUST)

`status = RECONCILING` 단계에서 diff_qty != 0 인 라인:
- 운영자 검토 → 사유 입력
- 승인 후 ADJUSTMENT movement 생성

### EI-535. 조정 movement (MUST)

```typescript
async function reconcileCountLine(line, reason, approver) {
  if (line.diffQty === 0) return;

  await db.$transaction(async (tx) => {
    // ADJUSTMENT movement
    await createMovement(tx, {
      direction: 'ADJUSTMENT',
      itemId: line.itemId,
      warehouseId: line.warehouseId,
      locationId: line.locationId,
      lotId: line.lotId,
      qty: Math.abs(line.diffQty),
      signedQty: line.diffQty,            // 부호 보존
      sourceType: 'COUNT_ADJUSTMENT',
      sourceId: `cnt:${line.cycleCountId}:${line.id}`,
      reason
    });
    // count line audit
    await tx.inventoryCountLine.update({
      where: { id: line.id },
      data: { /* approval meta */ }
    });
  });
}
```

### EI-538. 차이 임계 (SHOULD)

조직별 임계치 설정:
- ≤ 1% — 자동 조정 가능 (L3 승인)
- 1~5% — L4 승인 필수
- > 5% — 재카운트 (count_round = 2) 의무 (EI-540)

---

## 5. 재확인 의무 (EI-540 ~ EI-549) — MUST, KR

### EI-540. 2회 카운트 원칙 (MUST)

한국 회계 감사 표준 — 큰 차이는 1차 카운트만으로 조정 X. 2차 재카운트 의무:

조건:
- 차이율 > 5% (or 절대값 > N개) 인 라인 자동 마킹
- count_round = 2 의 별도 cycle_count 자동 생성 (해당 라인만 scope)
- 같은 사람이 1차 / 2차 카운트 X (다른 작업자)

### EI-545. 2차 결과 결정 (MUST)

| 1차 / 2차 결과 | 처리 |
|---|---|
| 일치 | 그 값으로 조정 |
| 불일치 | 3차 (관리자 입회) 또는 위 / 아래 평균값 + 별도 audit |
| 1차 결과만 정상 (시스템 잔고와 일치) | 1차 카운트 오류 가정, 차이 0 처리 |

---

## 6. 일정 / 자동화 (EI-550 ~ EI-569)

### EI-550. CYCLE 카운트 자동 일정 (SHOULD)

- 분기별 (3개월) 전수 권장
- 매월 카테고리 순환 (12개 카테고리 → 매달 1개)
- ABC 분석 — A 등급 (고가) 매월 / B (중) 분기 / C (저) 반기

### EI-555. 자동 트리거 (SHOULD)

- 음수 잔고 발견 시 → 자동 SPOT 카운트 생성 + 알림
- 무결성 차이 (EI-260) → 자동 SPOT
- 유통기한 임박 lot → 자동 SPOT

---

## 7. 권한 / 감사 (EI-580 ~ EI-599)

### EI-580. 권한

| 작업 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| 카운트 입력 | ✅ | ✅ | ✅ | ⚠️ |
| 카운트 시작 / 종료 | ❌ | ✅ | ✅ | ⚠️ |
| 차이 조정 승인 (≤1%) | ❌ | ✅ | ✅ | ⚠️ |
| 차이 조정 승인 (>1%) | ❌ | ❌ | ✅ | ⚠️ |
| 2차 카운트 면제 | ❌ | ❌ | ⚠️ (audit) | ✅ |
| 권한 분리 (입력자 ≠ 승인자) | (강제) | | | |

### EI-590. 감사

| action | 시점 |
|---|---|
| `inventory.cycle_count.started` | 카운트 시작 |
| `inventory.cycle_count.line_counted` | 라인 입력 |
| `inventory.cycle_count.line_overwritten` | 라인 덮어쓰기 |
| `inventory.cycle_count.reconciled` | 차이 조정 완료 |
| `inventory.cycle_count.recount_triggered` | 2차 카운트 발생 |
| `inventory.cycle_count.completed` | 전체 완료 |

---

## 8. 참조

- 게이트: `feature_flags.md` (`inventory.cycle_count`)
- 차이 조정 movement: `stock_movement.md` (EI-121, EI-150)
- FROZEN 상태: `warehouse.md` (EI-430)
- 무결성 검증: `stock_balance.md` (EI-260)
- 스키마: `../schemas/tables/inventory_cycle_counts.sql`
