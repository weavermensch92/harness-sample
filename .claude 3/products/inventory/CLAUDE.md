# Inventory Module — CLAUDE.md

> **모듈명**: Inventory (재고 / 자산 / 평가)
> **Prefix**: EI-xxx
> **버전**: v0.1 (Phase 0)
> **상위**: `../CLAUDE.md`

---

## 1. 정체성

품목 마스터 → 입출고 → 잔고 → 평가 → 실사 — 재고 lifecycle 전체. KR 식품위생법 / 약사법 / 화장품법 / K-IFRS 도메인 룰 내장.

**Phase 0 핵심 책임**:
- 품목 마스터 (SKU + 단위 + 카테고리)
- 입출고 movement (append-only, 멱등)
- 잔고 / 가용 / 예약 (qty - reserved - allocated)
- 로트 / 시리얼 / 유통기한 추적
- 창고 / 위치 트리 (zone/aisle/rack/bin)
- 재고 실사 (3 모드, 차이>5% 2차 카운트 의무)
- 원가 평가 (FIFO / 이동평균, K-IFRS)

---

## 2. 도메인 모델

```
items (마스터) ─→ movements (이동) ─→ balances (잔고) ─→ valuation (평가)
                       ↓                    ↓
                  lots/serials         reservations
                       ↓
              cycle_counts (실사)
```

핵심 엔티티: `Item`, `Movement` (IN/OUT/TRANSFER/ADJUSTMENT), `Balance`, `Reservation`, `Lot`, `Serial`, `Warehouse`, `Location`, `CycleCount`, `CostLayer` (FIFO), `AvgCost` (이동평균).

---

## 3. Phase 상태

### ✅ Phase 0 (현재) — v0.2

| 영역 | 상태 |
|---|---|
| Rules (9) | ✅ 완료 — EI-024 (물리 속성, v0.2) 추가 |
| Schemas (8 테이블) | ✅ 완료 — 16개 ENUM (`movement_source` v0.2 RETURN 추가) |
| Screens INDEX (EIS-xxx) | ✅ 완료 |
| 평가 (FIFO + Moving Avg) | ✅ 완료 (상호 배타 토글) |
| Lot / Serial 추적 | ✅ 완료 (KR 법정 의무) |
| Feature Flags (12) | ✅ 완료 |
| **Cross-module 정합 (v0.2)** | ✅ RETURN movement / weight·volume 컬럼 |
| 코드 (boilerplate) | ⚠️ Phase 1+ |

### ⏸ Phase 1+ (예정)

| 영역 | 비고 |
|---|---|
| 자동 발주 / 보충 (EI-700~) | 안전재고 / lead time 기반 |
| 회수 (Recall) 추적 (EI-355) | lot 단위 거래처별 추적 |
| 평가감 별도 테이블 (EI-645) | 저가법 처리 이력 |
| 매입 세금계산서 연동 (EI-800~) | KR 부가가치세 |
| 회계 모듈 연동 | 평가액 → GL 분개 |

---

## 4. 디렉터리 구조

```
inventory/
├── CLAUDE.md
├── rules/
│   ├── INDEX.md
│   ├── item_master.md       (EI-001~099)
│   ├── stock_movement.md    (EI-100~199)
│   ├── stock_balance.md     (EI-200~299)
│   ├── lot_tracking.md      (EI-300~399)
│   ├── warehouse.md         (EI-400~499)
│   ├── cycle_count.md       (EI-500~599)
│   ├── valuation.md         (EI-600~699)
│   └── feature_flags.md     (EI-900~999)
├── schemas/
│   ├── INDEX.md
│   └── tables/              (8 SQL 파일)
└── screens/
    └── INDEX.md             (EIS-xxx)
```

---

## 5. 외부 의존 (소비)

| 외부 | 용도 |
|---|---|
| `organizations` | 조직 |
| `facilities` | 시설 / 사업장 |
| `users` | created_by / 카운트 입력자 등 |

> Reservation 의 source = ORDER 는 외부 주문 시스템 의존 (FK X, application 레벨).

---

## 6. 외부 발신 (이벤트)

| 이벤트 | 시점 | 페이로드 |
|---|---|---|
| `inventory.movement.recorded` | IN/OUT/TRANSFER/ADJUSTMENT | itemId / warehouseId / qty / direction |
| `inventory.balance.adjusted` | 잔고 변경 (movement 반영 후) | itemId / warehouseId / oldQty / newQty |
| `inventory.lot.expired` | lot 만료 시점 도달 | lotId / itemId / expiredAt |
| `inventory.lot.recalled` | lot 회수 발동 | lotId / reason |
| `inventory.cycle_count.completed` | 실사 완료 | countId / discrepancies |
| `inventory.month_closed` | 월결산 마감 | period / closedBy |
| `inventory.feature_flag.changed` | 토글 변경 | feature_key |

소비측:
- logistics (lot expired 시 진행 중 배송 알림)
- payroll (piecework task_completed → work_log, Phase 1+)
- reports (캐시 무효화 / immutable)

---

## 7. 외부 구독 (수신)

| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `DELIVERY_DISPATCHED` | logistics | OUT movement 자동 생성 (예약 → 실 출고) |
| `DELIVERY_CANCELLED` | logistics (IN_TRANSIT 전) | reservation 해제 |
| `RETURN_RECEIVED` | logistics | IN movement 자동 생성 (lot_id 보존) |

---

## 8. 핵심 원칙 (요약, 상세 `rules/INDEX.md` § 3)

1. **append-only movement** — 정정은 REVERSAL row
2. **잔고 = movement 합계** — 무결성 검증 cron, 자동 보정 금지
3. **시점별 이력 (lot.expires_at, cost_layer)** — UPDATE 금지
4. **TRANSFER = OUT+IN 짝** — paired_id 로 묶음
5. **2차 카운트 의무 (한국 회계 감사)** — 차이>5% 자동 트리거
6. **K-IFRS 준수** — FIFO / 가중평균 허용 (LIFO 금지)
7. **평가 방법 상호 배타** — fifo ↔ moving_avg 동시 ON 차단
8. **마감일 차단** — closed_period 이전 movement INSERT 금지
9. **lot/serial 추적은 토글** — `inventory.lot_tracking` / `serial_tracking`

---

## 9. KR 법령 준수

| 영역 | 근거법 |
|---|---|
| 식품 lot 추적 | 식품위생법 §10 |
| 의약품 lot 추적 | 약사법 §47 |
| 화장품 lot 추적 | 화장품법 §10 |
| 의료기기 추적 | 의료기기법 §13 |
| 위험물 보관 | 위험물안전관리법 |
| 재고 평가 (저가법) | K-IFRS §2.9 |

법정 보존: 회계장부 10년 (상법 §33), 매입 세금계산서 5년 (부가가치세법 §32).

---

## 10. 코드 정합성 (boilerplate)

| 룰 | 예상 코드 위치 |
|---|---|
| EI-100 (movement) | `business/inventory/handlers/movement-handler.ts` |
| EI-150 (REVERSAL) | `business/inventory/services/reversal-service.ts` |
| EI-220 (reservation TTL) | `business/inventory/jobs/reservation-expiry-cron.ts` |
| EI-260 (무결성 검증) | `business/inventory/jobs/integrity-check-cron.ts` |
| EI-345 (lot 만료 알림) | `business/inventory/jobs/lot-expiry-cron.ts` |
| EI-540 (2차 카운트) | `business/inventory/services/cycle-count-service.ts` |
| EI-615 (FIFO 차감) | `business/inventory/services/fifo-cost-service.ts` |
| EI-625 (이동평균 갱신) | `business/inventory/services/moving-avg-service.ts` |

Phase 1 우선 구현: EI-100 (movement + 멱등), EI-220 (reservation), EI-615/625 (평가).

---

## 11. 빠른 참조

- 룰: `./rules/INDEX.md`
- 스키마: `./schemas/INDEX.md`
- 화면: `./screens/INDEX.md`
- 인접 모듈: `../payroll/CLAUDE.md`, `../logistics/CLAUDE.md`, `../reports/CLAUDE.md`
- 공통 룰: `../../rules/permissions.md`, `../../rules/database.md`

---

## 12. 다음 단계 (Phase 1 진입 조건)

- [x] `movement_source` ENUM 에 `RETURN` 추가 마이그레이션 (logistics 정합) — **v0.2**
- [x] inventory_items 에 `weight` / `volume` 컬럼 추가 (logistics 적재 검증 정합) — **v0.2**
- [ ] EI-100 movement-handler.ts (멱등 + 트랜잭션 정합)
- [ ] EI-220 reservation-service.ts + TTL cron
- [ ] EI-260 integrity-check cron (movement 합계 vs balance)
- [ ] EI-345 lot 만료 알림 cron (30/7/1일)
- [ ] EI-615 FIFO 레이어 차감 + EI-625 이동평균 갱신
- [ ] 자동 발주 (Phase 1+ EI-700~)
