# Logistics Schemas — 인덱스

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (D 트랙 초안)
> **DDL 규약**: `../../../rules/database.md`

---

## 0. 적용 정책

`payroll/schemas/INDEX.md`, `inventory/schemas/INDEX.md` 와 동일 — Prisma 가 정식 마이그레이션 소스, 이 SQL 파일은 도메인 의도 문서화 + 비-Prisma 도구 참조.

---

## 1. 테이블 일람

| 파일 | 테이블 | 주제 | 룰 |
|---|---|---|---|
| `tables/logistics_deliveries.sql` | `logistics_deliveries` (+`delivery_lines`) | 배송 + 라인 | EL-001~099 |
| `tables/logistics_drivers.sql` | `logistics_drivers` (+`vehicles`) | 기사 / 차량 | EL-100~199 |
| `tables/logistics_routes.sql` | `logistics_routes` (+`route_stops`) | 묶음 배송 | EL-200~299 |
| `tables/logistics_tracking_events.sql` | `logistics_tracking_events` (+`pods`) | 추적 / POD | EL-300~399 |
| `tables/logistics_tariffs.sql` | `logistics_tariffs` (+`region_surcharges`) | 운임 단가 / 도서산간 | EL-400~499 |
| `tables/logistics_return_requests.sql` | `logistics_return_requests` (+`return_lines`) | 반품 처리 | EL-500~599 |
| `tables/logistics_feature_flags.sql` | `logistics_feature_flags` | 모듈 기능 토글 | EL-900~999 |

> Phase 1+ 예정: `logistics_carrier_configs` (carrier 키 / secrets), `logistics_settlements` (정산), `logistics_sla_policies`.

---

## 2. ENUM 정의

| 타입 | 값 | 위치 |
|---|---|---|
| `delivery_direction` | OUTBOUND / RETURN | deliveries |
| `delivery_type` | STANDARD / EXPRESS / SAME_DAY / SCHEDULED | deliveries |
| `delivery_status` | DRAFT / ASSIGNED / IN_TRANSIT / DELIVERED / FAILED / CANCELLED | deliveries |
| `driver_status` | ACTIVE / SUSPENDED / TERMINATED | drivers |
| `vehicle_status` | ACTIVE / MAINTENANCE / RETIRED | drivers (vehicles) |
| `route_status` | PLANNED / IN_PROGRESS / COMPLETED / CANCELLED | routes |
| `route_stop_status` | PENDING / VISITED / SKIPPED | routes |
| `pod_recipient_kind` | SELF / DELEGATE / DOORSTEP / SECURITY | tracking_events (pods) |
| `return_status` | REQUESTED / APPROVED / REJECTED / PICKED_UP / RECEIVED / INSPECTED / COMPLETED / CANCELLED | return_requests |
| `return_reason` | CUSTOMER_REGRET / DEFECT / WRONG_ITEM / DAMAGED_TRANSIT / SYSTEM_ERROR | return_requests |
| `return_request_source` | CUSTOMER / SYSTEM / OPERATOR | return_requests |
| `return_cost_bearer` | BUYER / SELLER / CARRIER | return_requests |
| `return_inspection` | PASS / PARTIAL / FAIL | return_requests |
| `return_refund_status` | PENDING / ISSUED / DECLINED | return_requests |

> `event_type` (tracking_events), `recipient_*` (deliveries PII), `carrier` (`self`/`cj`/...) 는 VARCHAR 로 운영 — ENUM 으로 묶기엔 변동성 큼.

---

## 3. 핵심 제약 (모듈 전체 불변)

| 제약 | 위치 | 의미 |
|---|---|---|
| `logistics_deliveries (org, order_id, order_line_no) UNIQUE` | deliveries | 주문 멱등 (EL-030) |
| `logistics_deliveries.recipient_*` PII 컬럼 | deliveries | 마스킹 / 5년 보존 (EL-070, EL-075) |
| `logistics_drivers (org, user_id) UNIQUE` | drivers | 1 user = 1 driver (EL-115) |
| `logistics_vehicles.vehicle_no ~ '^[0-9]{2,3}[가-힣][0-9]{4}$'` | drivers | KR 차량번호 (EL-135) |
| `logistics_route_stops (route_id, sequence_no) UNIQUE` | routes | 방문 순서 단일 |
| `logistics_route_stops (route_id, delivery_id) UNIQUE` | routes | delivery 1 stop 1 회 |
| `logistics_tracking_events (delivery_id, source, source_id) UNIQUE NULLS NOT DISTINCT` | tracking_events | carrier 콜백 멱등 (EL-318) |
| `logistics_pods (delivery_id) UNIQUE` | tracking_events (pods) | 1 delivery = 1 POD |
| `logistics_tariffs (org, carrier, code, effective_from) UNIQUE` | tariffs | 시점별 단가 이력 (EL-415) |
| `logistics_return_requests (org, original_delivery_id) UNIQUE` | return_requests | 1 원배송 = 1 반품 (Phase 0) |
| `logistics_feature_flags (org, scope_type, scope_id, feature_key) UNIQUE` | feature_flags | 토글 스코프별 1 row |
| 좌표 = `NUMERIC(10, 7)` | tracking, pods | 7자리 ~1cm. 운영 5자리 권장 |
| 거리 = `NUMERIC(10, 3)` km | routes, deliveries | 1m 단위 |
| 통화 = `NUMERIC(14, 0)` | tariffs, deliveries | KRW 정수 |

---

## 4. 인덱스 전략

조회 우선:
- 활성 delivery (organization, status) WHERE deleted_at IS NULL
- 기사별 진행 중 (driver_id, status) WHERE driver_id IS NOT NULL
- 시간 임박 배송 (scheduled_at) WHERE status IN ('DRAFT', 'ASSIGNED')
- 추적 시간순 (delivery_id, event_at DESC)
- 면허 / 보험 만료 임박 (license_expires_at) WHERE status='ACTIVE'
- 운임 단가 시점 조회 (org, carrier, effective_from DESC)
- 반품 대기 (status, requested_at) WHERE status IN ('REQUESTED', 'APPROVED')

---

## 5. 마이그레이션 순서 (v0.1 신규 적용)

1. **ENUM 정의**: 13개
2. **drivers + vehicles** (organizations / users 의존만)
3. **routes** (drivers / vehicles 의존)
4. **deliveries** (drivers / vehicles / routes / inventory_warehouses 의존)
5. **route_stops** (routes / deliveries 의존)
6. **delivery_lines** (deliveries / inventory_items 의존)
7. **tracking_events + pods** (deliveries 의존)
8. **tariffs + region_surcharges** (organizations 의존만)
9. **return_requests + return_lines** (deliveries / delivery_lines / inventory_warehouses 의존)
10. **feature_flags** (organizations 의존만)

> ⚠️ inventory 모듈의 `movement_source` ENUM 에 `RETURN` 값 추가 필요 (EL-550 환원 movement). 별도 alter 마이그레이션.

---

## 6. 모듈 외부 의존

| 외부 테이블 | 참조 컬럼 |
|---|---|
| `organizations` | 모든 테이블의 organization_id |
| `users` | drivers.user_id, deliveries.created_by, pods.created_by, tariffs.created_by, feature_flags.changed_by |
| `inventory_warehouses` | deliveries.warehouse_id, routes.warehouse_id, return_requests.target_warehouse_id |
| `inventory_items` | delivery_lines.item_id |
| `inventory_lots`, `inventory_serials` | delivery_lines.lot_id / serial_id (옵션) |

→ 모든 외부 참조는 ON DELETE RESTRICT — 의존 데이터 보존.

---

## 7. Phase 1+ 예정 테이블 (미생성)

- `logistics_carrier_configs` — carrier API 키 / 시크릿 (vault 연동)
- `logistics_settlements` — 월간 carrier 정산 (EL-440)
- `logistics_sla_policies` — 시간 약속 / 지연 알림 정책
- `logistics_insurance_claims` — 사고 / 분실 보험 처리
- `logistics_consent_logs` — PII 동의 이력 (운전자 / 수령자)

---

## 8. 참조

- 룰 카탈로그: `../rules/INDEX.md`
- DB 규약: `../../../rules/database.md`
- 동일 메커니즘 (feature_flags): `../../payroll/schemas/tables/payroll_feature_flags.sql`, `../../inventory/schemas/tables/inventory_feature_flags.sql`
- 외부 의존 모듈: `../../inventory/schemas/INDEX.md`, `../../payroll/schemas/INDEX.md`
