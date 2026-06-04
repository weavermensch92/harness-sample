# Logistics Module — CLAUDE.md

> **모듈명**: Logistics (배송 / 물류 / 운송)
> **Prefix**: EL-xxx
> **버전**: v0.1 (Phase 0)
> **상위**: `../CLAUDE.md`

---

## 1. 정체성

배송 lifecycle 의 허브 — 주문 → 배차 → 출고 → 추적 → 수령 → (반품). inventory 와 payroll 의 트리거 발신원. KR 화물자동차운수사업법 / 개인정보보호법 / 전자상거래법 / 청소년보호법 도메인 룰 내장.

**Phase 0 핵심 책임**:
- Delivery lifecycle (DRAFT→ASSIGNED→IN_TRANSIT→DELIVERED/FAILED/CANCELLED)
- Driver / Vehicle 마스터 + 면허 / 보험 만료 차단
- Route (묶음 배송, 외부 routing API)
- Tracking events (append-only) + POD (사인 / 사진 / 실명확인)
- Shipping cost (운임 + 도서산간 surcharge)
- Returns (전자상거래법 청약철회 7일)
- Carrier 어댑터 (CJ / 한진 / 우체국 / 롯데, Strategy 패턴)

---

## 2. 도메인 모델

```
delivery (lifecycle)
   ├─ delivery_lines (품목)
   ├─ tracking_events (append-only)
   ├─ pod (1:1)
   ├─ route → route_stops (묶음)
   └─ return_request → return_lines

driver ─→ vehicle (배차 시 1:1)
tariff (시점별 이력) → shipping_cost (배송별 산정)
```

핵심 엔티티: `Delivery`, `DeliveryLine`, `Driver`, `Vehicle`, `Route`, `RouteStop`, `TrackingEvent`, `Pod`, `Tariff`, `RegionSurcharge`, `ReturnRequest`, `ReturnLine`.

---

## 3. Phase 상태

### ✅ Phase 0 (현재) — v0.2

| 영역 | 상태 |
|---|---|
| Rules (8) + INDEX | ✅ 완료 — EL-160 / EL-422 (UOM 변환 + NULL 처리, v0.2) |
| Schemas (7 테이블) | ✅ 완료 — 13개 ENUM |
| Screens INDEX (ELS-xxx) | ✅ 완료 |
| Carrier 어댑터 인터페이스 | ✅ 룰 정의 (구현은 Phase 1+) |
| POD (사인 / 사진 / 실명확인) | ✅ 완료 |
| Returns (전자상거래법) | ✅ 완료 — `rtn:` prefix 정합 (v0.2) |
| Feature Flags (14) | ✅ 완료 |
| **Cross-module 정합 (v0.2)** | ✅ inventory 의 RETURN / weight / volume 활용 |
| 코드 (boilerplate) | ⚠️ Phase 1+ |

### ⏸ Phase 1+ (예정)

| 영역 | 비고 |
|---|---|
| `logistics_carrier_configs` 테이블 | API 키 / secrets (vault 연동) |
| `logistics_settlements` 테이블 | 월간 carrier 정산 |
| `logistics_sla_policies` 테이블 | 시간 약속 / 지연 알림 |
| `logistics_consent_logs` 테이블 | PII 동의 이력 (운전자 / 수령자) |
| Carrier 어댑터 실 구현 (CJ / 한진 / 우체국 / 롯데) | 각 carrier API |
| POD 회수 / 분쟁 처리 | 사진 변경 / 사인 거부 분쟁 |
| Insurance / 보험 처리 | 차량 사고 / 분실 |
| 부분 반품 (1 원배송 → N 반품) | 현재는 1:1 |

---

## 4. 디렉터리 구조

```
logistics/
├── CLAUDE.md
├── rules/
│   ├── INDEX.md
│   ├── delivery.md           (EL-001~099)
│   ├── driver_vehicle.md     (EL-100~199)
│   ├── route.md              (EL-200~299)
│   ├── tracking_pod.md       (EL-300~399)
│   ├── shipping_cost.md      (EL-400~499)
│   ├── returns.md            (EL-500~599)
│   ├── carrier.md            (EL-600~699)
│   └── feature_flags.md      (EL-900~999)
├── schemas/
│   ├── INDEX.md
│   └── tables/               (7 SQL 파일)
└── screens/
    └── INDEX.md              (ELS-xxx)
```

---

## 5. 외부 의존 (소비)

| 외부 | 용도 |
|---|---|
| `organizations` | 조직 |
| `users` | driver = user (1:1) |
| `inventory_warehouses` | delivery / route 의 출발 창고 |
| `inventory_items` | delivery_lines.item_id |
| `inventory_lots`, `inventory_serials` | 추적 lot / serial (옵션) |
| 외부 carrier API | CJ / 한진 / 우체국 / 롯데 (Phase 1+ 구현) |
| 외부 routing API | Google Routes / TMap (route 최적화) |

---

## 6. 외부 발신 (이벤트)

| 이벤트 | 시점 | 페이로드 | 소비측 영향 |
|---|---|---|---|
| `logistics.delivery.drafted` | DRAFT 생성 | deliveryId / orderId / items | inventory: reservation 생성 |
| `logistics.delivery.assigned` | 배차 | deliveryId / driverId / vehicleId | (외부 알림) |
| `logistics.delivery.dispatched` | IN_TRANSIT | deliveryId / dispatchedAt | **inventory: OUT movement** |
| `logistics.delivery.completed` | DELIVERED | deliveryId / podId / driverId | **payroll: WorkLog (기사)** |
| `logistics.delivery.failed` | FAILED | deliveryId / reason | (운영자 알림) |
| `logistics.delivery.cancelled` | CANCELLED (IN_TRANSIT 전) | deliveryId / reason | inventory: reservation 해제 |
| `logistics.return.received` | RECEIVED | originalDeliveryId / returnDeliveryId | inventory: IN movement (RETURN) |
| `logistics.return.refunded` | INSPECTED → 환불 발행 | runId / amount / reason | reports: 반품률 캐시 invalidate |
| `logistics.feature_flag.changed` | 토글 변경 | feature_key |  |

---

## 7. 외부 구독 (수신)

| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `ORDER_CONFIRMED` | (외부 주문 시스템) | Delivery DRAFT 자동 생성 + inventory.reserve |
| `ORDER_CANCELLED` | (외부) | Delivery 취소 (IN_TRANSIT 이상이면 거부) |
| `inventory.lot.expired` | inventory | 진행 중 배송에 expired lot 포함 시 알림 |

---

## 8. 핵심 원칙 (요약, 상세 `rules/INDEX.md` § 3)

1. **Delivery 가 모듈 허브** — DELIVERY_DISPATCHED → inventory OUT, DELIVERY_COMPLETED → payroll WorkLog
2. **상태 머신 단방향** — 역방향 / skip 금지. 강제 변경은 Super + audit
3. **외부 carrier 콜백 멱등 2중** — processed_events + UNIQUE
4. **위치 정보 = PII** — 마스킹 / 보존 기간 / 암호화 강제
5. **POD 의무 카테고리** — 의약품 / 고가 / B2B 는 사진+사인+실명확인
6. **운임 단가 시점별 이력** — UPDATE 금지, 새 row
7. **Carrier 어댑터는 토글** — `logistics.carrier_*` 별도
8. **반품 = 역 배송** — 새 delivery row (direction='RETURN')
9. **dev / local 강제 mock** — 실 carrier API 차단 (운송장 발행 사고 방지)

---

## 9. KR 법령 준수

| 영역 | 근거법 |
|---|---|
| 화물자동차 운수사업 | 화물자동차운수사업법 §3 (등록), §5 (운송약관) |
| 개인정보 (수령자 / 운전자) | 개인정보보호법 §15 (수집), §29 (안전조치) |
| 전자상거래 (반품 / 환불) | 전자상거래법 §6 (5년 보존), §17 (청약철회 7일), §18 (효과) |
| 의약품 본인 수령 | 약사법 §44 |
| 청소년 유해물품 (주류 / 담배) | 청소년보호법 §28 |
| 차량 보험 | 자동차손해배상보장법 |
| 차량 검사 | 자동차관리법 |

법정 보존: 거래 기록 5년 (전자상거래법 §6 ③), 위치 정보 30일 (운전자) / 5년 (배송).

---

## 10. 코드 정합성 (boilerplate)

| 룰 | 예상 코드 위치 |
|---|---|
| EL-040 (이벤트 발행 outbox) | `business/logistics/handlers/order-handler.ts` |
| EL-150 (만료 검증) | `business/logistics/services/assignment-validator.ts` |
| EL-160 (적재 검증) | `business/logistics/services/capacity-validator.ts` |
| EL-230 (route 최적화) | `business/logistics/services/route-optimizer.ts` |
| EL-330 (POD + DELIVERED 전이) | `business/logistics/handlers/pod-handler.ts` |
| EL-420 (운임 산정) | `business/logistics/services/shipping-cost-service.ts` |
| EL-550 (반품 inventory IN) | `business/logistics/handlers/return-received-handler.ts` |
| EL-620 (carrier 어댑터) | `business/logistics/adapters/carrier/{cj,hanjin,...}.ts` |
| EL-635 (carrier callback) | `business/logistics/handlers/carrier-callback.ts` |

Phase 1 우선 구현: EL-040 (delivery saga), EL-330 (POD), EL-620 (mock 어댑터 우선).

---

## 11. 빠른 참조

- 룰: `./rules/INDEX.md`
- 스키마: `./schemas/INDEX.md`
- 화면: `./screens/INDEX.md`
- 인접 모듈: `../payroll/CLAUDE.md`, `../inventory/CLAUDE.md`, `../reports/CLAUDE.md`
- 공통 룰: `../../rules/permissions.md`, `../../rules/integration.md`, `../../rules/database.md`

---

## 12. 다음 단계 (Phase 1 진입 조건)

- [ ] EL-040 outbox + delivery-handler 구현 (saga 정합)
- [ ] EL-150 / EL-160 배차 검증 (만료 / 적재) 헬퍼
- [ ] EL-330 POD + DELIVERED 전이 트랜잭션
- [ ] EL-620 carrier 어댑터 - mock 우선 구현 (개발 환경)
- [ ] EL-635 carrier callback HMAC 검증 + 멱등 처리
- [ ] EL-555 RETURN type 창고 시드 (조직별 1개 자동 생성)
- [x] inventory `movement_source` ENUM 에 `RETURN` 추가 (정합 마이그레이션) — **v0.2**
- [x] inventory_items 의 `weight` / `volume` 컬럼 추가 (적재 검증 정합) — **v0.2**
- [ ] `business/logistics/services/uom-converter.ts` — 무게 / 부피 단위 변환 헬퍼 (EI-024 활용)
- [ ] `business/logistics/handlers/return-received-handler.ts` — inventory IN movement (sourceType='RETURN')
- [ ] 운전자 location_consent flow (PII 동의 ER-080)
- [ ] Phase 1+ 테이블 추가: carrier_configs / settlements / sla_policies / consent_logs
