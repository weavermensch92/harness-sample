# Logistics Rules — 인덱스

> **Prefix**: EL-xxx
> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (D 트랙 초안)
> **참조**: `../../../rules/permissions.md`, `../../../rules/integration.md`, `../../../rules/database.md`

---

## 0. 로딩 가이드 (E-901 / E-902)

이 인덱스 + 각 룰 파일의 TL;DR 만 우선 로드. 상세 섹션은 명시 요청 시.

---

## 1. 키워드 → 파일 트리거

| 키워드 | 파일 | TL;DR |
|---|---|---|
| 배송 / delivery / 주문 처리 / 출고 / 배차 | `delivery.md` | EL-001~099 |
| 기사 / 운전자 / 차량 / 면허 / 적재량 | `driver_vehicle.md` | EL-100~199 |
| 경로 / route / 묶음 배송 / 다배송 / 최적화 | `route.md` | EL-200~299 |
| 추적 / 위치 / GPS / POD / 수령확인 / 사진 / 사인 | `tracking_pod.md` | EL-300~399 |
| 운임 / 단가 / 배송료 / 정산 / 도서산간 | `shipping_cost.md` | EL-400~499 |
| 반품 / 회수 / RMA / 수거 | `returns.md` | EL-500~599 |
| 외부 배송사 / CJ / 한진 / 우체국 / API | `carrier.md` | EL-600~699 |
| 기능 토글 / feature flag | `feature_flags.md` | EL-900~999 |

---

## 2. ID 네임스페이스

| 범위 | 주제 | 파일 | 상태 |
|---|---|---|---|
| EL-001~099 | Delivery lifecycle (생성 / 배차 / 출고 / 완료) | `delivery.md` | ✅ |
| EL-100~199 | Driver / Vehicle | `driver_vehicle.md` | ✅ |
| EL-200~299 | Route / 묶음 배송 | `route.md` | ✅ |
| EL-300~399 | Tracking / POD | `tracking_pod.md` | ✅ |
| EL-400~499 | Shipping Cost / 운임 / 정산 | `shipping_cost.md` | ✅ |
| EL-500~599 | Returns / 반품 처리 | `returns.md` | ✅ |
| EL-600~699 | Carrier / 외부 배송사 연동 (KR) | `carrier.md` | ✅ |
| EL-700~799 | (예약) SLA / 시간 약속 / 지연 알림 |  | — |
| EL-800~899 | (예약) 보험 / 손해배상 |  | — |
| EL-900~999 | Feature Flags | `feature_flags.md` | ✅ |

**강제 수준**: MUST / SHOULD / MAY.

---

## 3. 핵심 원칙 (모듈 전체 MUST)

1. **Delivery 가 모듈 허브 (이벤트 발신원)** — `DELIVERY_DISPATCHED` → inventory OUT, `DELIVERY_COMPLETED` → payroll WorkLog. 외부 모듈 의존성의 출발점.
2. **상태 머신 단방향** — DRAFT → ASSIGNED → IN_TRANSIT → DELIVERED / FAILED / CANCELLED. 역방향 금지.
3. **멱등 — 외부 carrier 콜백 / 모바일 앱 보고는 2중 방어** — `processed_events` + 내부 자연 키 UNIQUE.
4. **위치 정보 = PII** — 운전자 / 수령자 위치는 개인정보. 마스킹 / 보존 기간 / 암호화 강제 (KR 개인정보보호법 §15).
5. **POD 의무** — 특정 카테고리 (의약품 / 고가 / B2B) 는 POD 강제. 사진 / 사인 / 실명확인.
6. **운임 단가 시점별 보존** — 단가표 변경은 새 row. 과거 배송 정산 시점 단가 유지.
7. **Carrier 어댑터는 토글** — 사용 carrier 만 ON. 자체 배송 / 외부 carrier 혼합 가능.
8. **반품 = 역 배송** — 새 delivery row (direction='RETURN'), 원 delivery 와 link.
9. **시간대 — 배송 약속 시각은 조직 timezone (Asia/Seoul 기본)**, 표시 변환은 Presentation.
10. **소수점 — 거리는 NUMERIC(10, 3) km, 수량은 NUMERIC(14, 4)**, 통화는 NUMERIC(14, 0) KRW 정수.
11. **기능 토글** — 모든 부가 기능은 `logistics_feature_flags` 게이트. 기본 OFF.

---

## 4. 모듈 외부와의 약속

### 발행 이벤트
| 이벤트 | 시점 | 페이로드 핵심 |
|---|---|---|
| `DELIVERY_DRAFTED` | Delivery 생성 (DRAFT) | deliveryId / orderId / items |
| `DELIVERY_ASSIGNED` | 기사 배정 | deliveryId / driverId / vehicleId / etaAt |
| `DELIVERY_DISPATCHED` | 출발 (창고 출고) | deliveryId / dispatchedAt | → **inventory OUT** |
| `DELIVERY_COMPLETED` | 수령 완료 (POD 확정) | deliveryId / driverId / completedAt / podId | → **payroll WorkLog** |
| `DELIVERY_FAILED` | 배송 실패 | deliveryId / reason / attemptCount |
| `DELIVERY_CANCELLED` | 취소 | deliveryId / cancelledBy / reason | → **inventory cancel** |
| `DELIVERY_RETURNED` | 반품 입고 완료 | originalDeliveryId / returnDeliveryId |
| `logistics.feature_flag.changed` | 토글 변경 |  |

### 구독 이벤트
| 이벤트 | 발행자 | 처리 |
|---|---|---|
| `ORDER_CONFIRMED` | (외부 / 주문 시스템) | Delivery DRAFT 자동 생성 + inventory.reserve |
| `ORDER_CANCELLED` | (외부) | Delivery 취소 (단, 이미 IN_TRANSIT 이상이면 거부) |
| `inventory.lot.expired` | Inventory | 진행 중 배송에 expired lot 포함 시 알림 |

상세: `../../../rules/integration.md`.

---

## 5. boilerplate 코드 정합성 (Phase 1+ 예정)

| 코드 | 룰 |
|---|---|
| `business/logistics/handlers/order-handler.ts` | EL-010, EL-020 |
| `business/logistics/jobs/dispatch-cron.ts` | EL-040 |
| `business/logistics/jobs/eta-tracker.ts` | EL-330 |
| `business/logistics/handlers/carrier-callback.ts` | EL-620 |
| (기존 boilerplate) `prisma Delivery 모델` | EL-001 |

---

## 6. Feature Flag 카탈로그 (기본값)

| feature_key | 기본값 | 설명 |
|---|---|---|
| `logistics.self_delivery` | ON | 자체 배송 (in-house driver) |
| `logistics.carrier_cj` | OFF | CJ대한통운 어댑터 |
| `logistics.carrier_hanjin` | OFF | 한진택배 어댑터 |
| `logistics.carrier_korea_post` | OFF | 우체국택배 어댑터 |
| `logistics.carrier_lotte` | OFF | 롯데택배 어댑터 |
| `logistics.route_optimization` | OFF | 자동 경로 최적화 |
| `logistics.real_time_tracking` | ON | 실시간 위치 추적 (PII 처리 필수) |
| `logistics.pod_signature` | ON | 사인 POD |
| `logistics.pod_photo` | ON | 사진 POD |
| `logistics.pod_id_verification` | OFF | 실명확인 POD (의약품 / 주류) |
| `logistics.return_handling` | ON | 반품 / 회수 |
| `logistics.delivery_sla_alerts` | ON | 지연 알림 |
| `logistics.driver_location_logging` | OFF | 운전자 위치 로그 (PII 동의 필수) |
| `logistics.delivery_window_strict` | OFF | 시간 약속 엄격 모드 (15분 단위) |

---

## 7. 참조

- 상위: `../CLAUDE.md`
- 권한: `../../../rules/permissions.md`
- 이벤트: `../../../rules/integration.md`
- DB: `../../../rules/database.md`
- 스키마: `../schemas/INDEX.md`
- 화면: `../screens/INDEX.md`
- 연동 모듈: `../../inventory/rules/INDEX.md`, `../../payroll/rules/INDEX.md`
