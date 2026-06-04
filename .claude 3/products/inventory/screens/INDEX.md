# Inventory Screens — 인덱스 (프레임)

> **상위**: `../CLAUDE.md`
> **상태**: Phase 0 — 목록과 라우팅 / 권한 매핑까지만. 실제 화면 / 디자인은 Phase 2+.
> **참조**: `../../../skills/designer/`, `../rules/INDEX.md`

---

## 0. 적용 정책

`payroll/screens/INDEX.md` 와 동일 — 화면 ID + 의도만 정의. 실제 React / 디자인은 Phase 2+ 디자이너 에이전트 핸드오프.

---

## 1. 화면 ID 네임스페이스

화면 ID = `EIS-xxx` (Inventory Screens). 룰 ID (EI-xxx) 와 구분.

| 범위 | 주제 | 우선순위 |
|---|---|---|
| EIS-001~019 | 본인 재고 조회 (현장 작업자) | P1 |
| EIS-100~149 | 재고 입출고 (L2 / L3) | P0 (필수) |
| EIS-150~199 | 재고 이동 / TRANSFER | P1 |
| EIS-200~249 | 재고 조회 / 잔고 / 가용 | P0 |
| EIS-250~299 | 예약 / 할당 관리 | P1 |
| EIS-300~349 | 로트 / 시리얼 / 유통기한 | P1 (lot_tracking ON 시) |
| EIS-400~449 | 창고 / 위치 관리 | P2 |
| EIS-500~549 | 재고 실사 (Cycle Count) | P1 |
| EIS-600~649 | 평가 보고서 / 회계 | P2 |
| EIS-700~749 | 발주 / 보충 (Phase 1+) | P3 |
| EIS-900~949 | Super 관리 (마스터 / feature flag) | P2 |

---

## 2. 화면 목록

### 2.1 현장 작업자 (L2, 모바일 우선)

| ID | 화면명 | 라우트 | 주 룰 | 비고 |
|---|---|---|---|---|
| EIS-001 | 빠른 입고 (바코드) | `/me/inbound` | EI-100, EI-110 | 바코드 스캔 + 수량 / lot |
| EIS-002 | 빠른 출고 (바코드) | `/me/outbound` | EI-100, EI-140 | 음수 차단 + lot 자동 픽업 |
| EIS-003 | 잔고 조회 (현장) | `/me/stock` | EI-200, EI-250 | 위치별 가용 |
| EIS-004 | 본인 작업 이력 | `/me/movements` | EI-100 | 본인이 등록한 movement |

### 2.2 입출고 관리 (L2 / L3)

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-100 | 입고 등록 (PURCHASE) | `/admin/inventory/inbound` | EI-100, EI-300, EI-610 |
| EIS-110 | 출고 등록 (수동) | `/admin/inventory/outbound` | EI-100, EI-140, EI-340 |
| EIS-120 | 조정 / ADJUSTMENT | `/admin/inventory/adjustment` | EI-121, EI-150 |
| EIS-130 | movement 정정 (REVERSAL) | `/admin/inventory/reverse/[id]` | EI-150 |
| EIS-140 | 마감일 / closed period | `/admin/inventory/closed-periods` | EI-170 |

### 2.3 재고 이동

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-150 | warehouse 간 이동 | `/admin/inventory/transfer/wh` | EI-440 |
| EIS-160 | location 간 이동 (빈 단위) | `/admin/inventory/transfer/loc` | EI-440 |
| EIS-170 | in-transit 추적 (Phase 1+) | `/admin/inventory/in-transit` | EI-445 |

### 2.4 잔고 / 가용 / 예약

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-200 | 잔고 대시보드 | `/admin/inventory/balances` | EI-210 |
| EIS-210 | 가용 재고 (item × warehouse) | `/admin/inventory/availability` | EI-250 |
| EIS-220 | 음수 재고 알림 | `/admin/inventory/negative-alerts` | EI-145 |
| EIS-230 | 무결성 차이 (cron) | `/admin/inventory/integrity-violations` | EI-260 |
| EIS-250 | 활성 예약 목록 | `/admin/inventory/reservations` | EI-220 |
| EIS-260 | 예약 수동 해제 | `/admin/inventory/reservations/[id]/release` | EI-225 |
| EIS-270 | TTL 만료 이력 | `/admin/inventory/reservations/expired` | EI-225 |

### 2.5 로트 / 시리얼 / 유통기한

| ID | 화면명 | 라우트 | 주 룰 | 게이트 |
|---|---|---|---|---|
| EIS-300 | lot 마스터 | `/admin/inventory/lots` | EI-300 | `inventory.lot_tracking` |
| EIS-310 | 만료 임박 lot (30/7/1일) | `/admin/inventory/lots/expiring` | EI-345 | `inventory.lot_tracking` |
| EIS-320 | QUARANTINED ↔ ACTIVE | `/admin/inventory/lots/[id]/quarantine` | EI-315 | `inventory.lot_tracking` |
| EIS-330 | 만료 폐기 처리 | `/admin/inventory/lots/[id]/dispose` | EI-348 | `inventory.lot_tracking` |
| EIS-340 | 회수 (Recall) 추적 | `/admin/inventory/recall/[lot_id]` | EI-355 | `inventory.lot_tracking` |
| EIS-350 | 시리얼 조회 | `/admin/inventory/serials` | EI-320 | `inventory.serial_tracking` |

### 2.6 창고 / 위치

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-400 | 창고 목록 / 등록 | `/admin/inventory/warehouses` | EI-410 |
| EIS-410 | 위치 트리 편집 | `/admin/inventory/warehouses/[id]/locations` | EI-420 |
| EIS-420 | FROZEN ↔ ACTIVE | `/admin/inventory/warehouses/[id]/freeze` | EI-435 |

### 2.7 재고 실사

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-500 | 실사 목록 / 일정 | `/admin/inventory/cycle-counts` | EI-500 |
| EIS-510 | 실사 시작 (FROZEN 자동) | `/admin/inventory/cycle-counts/[id]/start` | EI-510 |
| EIS-520 | 카운트 입력 (모바일) | `/me/cycle-counts/[id]/lines` | EI-520 |
| EIS-530 | 차이 조정 / 승인 | `/admin/inventory/cycle-counts/[id]/reconcile` | EI-530 |
| EIS-540 | 2차 카운트 자동 생성 | `/admin/inventory/cycle-counts/[id]/recount` | EI-540 |

### 2.8 평가 / 보고서

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-600 | 평가 단가 (item × warehouse) | `/admin/inventory/valuation` | EI-650 |
| EIS-610 | FIFO 레이어 조회 | `/admin/inventory/fifo-layers` | EI-610 |
| EIS-620 | 월별 평가 보고서 | `/admin/inventory/reports/valuation` | EI-650 |
| EIS-630 | 평가감 처리 | `/admin/inventory/write-down` | EI-640 |

### 2.9 Super 관리

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| EIS-900 | 카테고리 마스터 | `/super/inventory/categories` | EI-030 |
| EIS-910 | UOM 변환 마스터 | `/super/inventory/uom` | EI-021 |
| EIS-920 | feature flag 매트릭스 | `/super/inventory/feature-flags` | EI-910 |
| EIS-930 | feature flag 변경 | `/super/inventory/feature-flags/[org]` | EI-930 |
| EIS-940 | 평가 방법 변경 (회계 결산) | `/super/inventory/valuation-method` | EI-630 |

---

## 3. 권한 매트릭스 (요약)

| 화면 그룹 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| EIS-001~004 (현장) | ❌ | ✅ | ✅ | ✅ | ✅ |
| EIS-100~140 (입출고) | ❌ | ⚠️ | ✅ | ✅ | ✅ |
| EIS-150~170 (이동) | ❌ | ⚠️ | ✅ | ✅ | ✅ |
| EIS-200~270 (잔고) | ❌ | ✅ (조회) | ✅ | ✅ | ✅ |
| EIS-300~350 (lot) | ❌ | ✅ (조회) | ✅ | ✅ | ✅ |
| EIS-400~420 (창고) | ❌ | ❌ | ✅ | ✅ | ✅ |
| EIS-500~540 (실사) | ❌ | ✅ (입력) | ✅ | ✅ | ✅ |
| EIS-600~630 (평가) | ❌ | ❌ | ✅ | ✅ | ✅ |
| EIS-900~940 (Super) | ❌ | ❌ | ❌ | ❌ | ✅ |

---

## 4. 다음 단계 (Phase 2+)

1. 화면 ID 별 명세 파일 (`screens/EIS-XXX.md`) — 와이어프레임 / 컴포넌트 트리 / 인터랙션
2. 디자이너 에이전트 호출 — `skills/designer/prompts/`
3. frontend-developer 구현 — `skills/frontend-developer/`
4. QA 시나리오 — `skills/qa-engineer/scenarios/permission-matrix.md` Inventory 행 추가

---

## 5. 참조

- 룰: `../rules/INDEX.md`
- 권한 매트릭스 상위: `../../../rules/permissions.md`
- payroll 동일 패턴: `../../payroll/screens/INDEX.md`
