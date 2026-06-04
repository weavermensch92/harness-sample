# Products — CLAUDE.md (4-Module ERP Suite)

> **묶음**: ERP Harness (Gridge AI MSP 와 별개 — D 트랙 운영 안정성 / KR 도메인)
> **버전**: 4-모듈 v0.2 (cross-module 정합 완료) — payroll v0.11+, inventory/logistics v0.2, reports v0.1
> **상위**: `../CLAUDE.md`
> **스코프**: KR 시장, Asia/Seoul timezone, KRW

---

## 1. 모듈 구성

| 모듈 | Prefix | 버전 | 역할 |
|---|---|---|---|
| **payroll** | EP- | v0.11+ (v0.2 cross) | 인건비 lifecycle (근태 → 급여 → 명세서 → 지급) |
| **inventory** | EI- | v0.2 | 재고 lifecycle (마스터 → 입출고 → 평가 → 실사) |
| **logistics** | EL- | v0.2 | 배송 lifecycle (주문 → 배차 → 추적 → POD → 반품) |
| **reports** | ER- | v0.1 | 집계 / 보존 / 배포 (3 모듈 데이터 조회) |

각 모듈 정체성은 `<module>/CLAUDE.md` 참조.

---

## 2. 모듈 간 흐름

```
            ORDER_CONFIRMED (외부)
                   │
                   ▼
         ┌──────────────────┐
         │     logistics    │
         │  (delivery 허브)  │
         └──┬───────────┬───┘
            │           │
   DISPATCHED│           │COMPLETED
   (출고)     │           │(수령 + POD)
            │           │
   ┌────────▼──┐  ┌─────▼──────┐
   │ inventory │  │  payroll   │
   │ OUT mvmt  │  │ work_log   │
   └────────┬──┘  │(기사 인건비)│
            │     └─────┬──────┘
            │           │
   RETURN   │     period_closed
   (반품IN) │           │
            │           │
            ▼           ▼
         ┌──────────────────┐
         │     reports      │
         │  (집계 / 캐시 /    │
         │   immutable)     │
         └──────────────────┘
```

핵심 트리거:
- **logistics → inventory**: `DELIVERY_DISPATCHED` (OUT), `RETURN_RECEIVED` (IN)
- **logistics → payroll**: `DELIVERY_COMPLETED` (기사 work_log)
- **payroll/inventory/logistics → reports**: 캐시 무효화 / period_closed → immutable

---

## 3. 공통 디자인 원칙 (4 모듈 일관)

### 3.1 데이터 무결성

1. **Append-only 사실 기록** — movement / payment / work_log / tracking_event / report_run 은 UPDATE 금지
2. **정정은 새 row** — REVERSAL / RETURN / 새 버전
3. **시점별 이력 보존** — UPDATE 금지, effective_from/to (compensation_settings, task_definitions, tariffs, lots, report_definitions)
4. **마감 후 immutable** — period_closed / month_closed 이벤트 발행 후 차단

### 3.2 멱등성

1. **2중 방어** — `processed_events` (이벤트 ID) + 자연 키 UNIQUE
2. **외부 콜백 멱등** — carrier webhook, ORDER_CONFIRMED 등 모두
3. **재시도 안전** — 같은 입력 재실행 = 같은 결과 또는 거부

### 3.3 권한 / 보안

1. **L1~L5 + Super 등급** — L1 본인, L2 팀, L3 시설, L4 조직, Super 전사
2. **권한 분리** — 입력자 ≠ 승인자 (payment, cycle_count, return inspection)
3. **PII 마스킹 필수** — 이름 / 전화 / 주소 / 위치 / SSN
4. **시크릿 store** — API 키 / DB 비밀번호는 vault, 환경변수 X
5. **dev / local 강제 mock** — 외부 carrier API / 실 이체 차단

### 3.4 기능 토글

1. **모든 부가 기능은 토글** — `{module}_feature_flags` 테이블 (4개 모두 동일 구조)
2. **스코프 우선순위** — TEAM > FACILITY > ORGANIZATION > 기본값
3. **의존성 검증** — A 가 B 의존 시 B 먼저 ON
4. **상호 배타** — `inventory.valuation_fifo` ↔ `valuation_moving_avg`
5. **카운트 의존** — `logistics.auto_carrier_routing` 은 carrier ≥ 2 ON 필요

### 3.5 데이터 타입 표준

| 종류 | 타입 |
|---|---|
| 통화 | `NUMERIC(14, 0)` KRW 정수 (반올림) |
| 수량 | `NUMERIC(14, 4)` (g / ml 단위) |
| 거리 | `NUMERIC(10, 3)` km |
| 좌표 | `NUMERIC(10, 7)` (운영 5자리 권장) |
| 비율 | `NUMERIC(5, 4)` (0.0625 = 6.25%) |

### 3.6 시간

- **timezone = Asia/Seoul** (조직 기본). 표시 변환은 Presentation
- DB 저장은 `TIMESTAMPTZ` (UTC). Application 변환
- 결제 / 배송 / 출퇴근 시각은 분 단위 그라뉼래리티

---

## 4. KR 법령 / 규제 매트릭스

### 4.1 노동 / 세무 (payroll)

| 영역 | 근거 |
|---|---|
| 임금 / 명세서 / 휴일 / 연장 | 근로기준법 §42, §43, §48, §54, §56 |
| 근로소득세 | 소득세법 §47, §134 |
| 일용직 (6%×45%) | 소득세법 §59, §129 |
| 4대보험 | 국민연금법 §6 / 건강보험법 §6 / 고용보험법 §10 / 산재법 §6 |

### 4.2 재고 / 회계 (inventory)

| 영역 | 근거 |
|---|---|
| 식품 lot 추적 | 식품위생법 §10 |
| 의약품 lot | 약사법 §47 |
| 화장품 lot | 화장품법 §10 |
| 의료기기 | 의료기기법 §13 |
| 재고 평가 | K-IFRS §2.9 (FIFO / 가중평균 / 저가법, LIFO 금지) |
| 회계장부 | 상법 §33 (10년 보존) |

### 4.3 물류 / 전자상거래 (logistics)

| 영역 | 근거 |
|---|---|
| 화물자동차 운수사업 | 화물자동차운수사업법 §3, §5 |
| 개인정보 (수령자 / 운전자) | 개인정보보호법 §15, §29 |
| 청약철회 / 환불 | 전자상거래법 §6, §17, §18 |
| 의약품 본인 수령 | 약사법 §44 |
| 청소년 유해물품 | 청소년보호법 §28 |
| 차량 보험 / 검사 | 자동차손해배상보장법, 자동차관리법 |

### 4.4 보고서 보존 (reports)

| 종류 | 보존 |
|---|---|
| 급여대장 / 4대보험 | 3년 (근로기준법 §42) |
| 원천세 / 부가세 | 5년 (소득세법 §164, 부가가치세법 §32) |
| 거래 기록 | 5년 (전자상거래법 §6 ③) |
| 회계장부 | 10년 (상법 §33) |
| audit log | 5년 (PII 노출 7년) |

---

## 5. Phase 0 → Phase 1 전환 조건

### Phase 0 완료 (현재)

- [x] 4 모듈 룰 / 스키마 / 화면 INDEX 동기 완료
- [x] KR 도메인 룰 통합 (각 모듈)
- [x] 이벤트 매트릭스 정의 (모듈 간 약속)
- [x] 권한 등급 / PII 마스킹 정책
- [x] Feature flag 메커니즘 (4 모듈 일관)

### Phase 1 진입 조건 (각 모듈 CLAUDE.md § 12)

**전 모듈 공통**:
- [ ] Outbox publisher worker (이벤트 발행 안정화)
- [ ] ProcessedEvent 멱등 헬퍼 단일화
- [ ] Saga 자동 resume + retry / backoff 정책
- [ ] 운영 진입점 (CLI / admin)
- [ ] PII 마스킹 자동 강제 (코드 검증)

**모듈별**:
- payroll: payment-handler / payslip-handler / 급여 saga
- inventory: movement-handler / reservation-service / FIFO·이동평균 service
- logistics: delivery saga / POD handler / mock carrier 어댑터
- reports: run-service / cache-invalidation / KR BUILTIN 9종

### Cross-module 정합 (Phase 1 진입 직전)

- [x] inventory `movement_source` ENUM 에 `RETURN` 추가 (logistics returns 정합) — **v0.2 (migrations/001)**
- [x] inventory_items 에 `weight` / `volume` 컬럼 추가 (logistics 적재 검증) — **v0.2 (migrations/002)**
- [x] payroll `work_log_source` 에 `DELIVERY` 안전 추가 (logistics → payroll 정합) — **v0.2 (migrations/003)**
- [x] logistics → inventory FK 진단 — **v0.2 (migrations/004, 진단 전용)**
- [ ] reports `period_closed` 이벤트 수신 → `is_immutable=true` 핸들러 (Phase 1)
- [x] 통합 권한 매트릭스 (`rules/permissions.md`) — **v0.1 (4 모듈 통합)**
- [x] 통합 이벤트 카탈로그 (`rules/integration.md`) — **v0.1**
- [x] DDL 규약 통합 (`rules/database.md`) — **v0.1**

---

## 6. 디렉터리 구조 (4-모듈 통합)

```
.claude/products/
├── CLAUDE.md                       ← 이 파일
├── payroll/
│   ├── CLAUDE.md
│   ├── rules/                      (10 룰)
│   ├── schemas/                    (10 SQL + INDEX)
│   └── screens/INDEX.md
├── inventory/
│   ├── CLAUDE.md
│   ├── rules/                      (8 룰 + INDEX)
│   ├── schemas/                    (8 SQL + INDEX)
│   └── screens/INDEX.md
├── logistics/
│   ├── CLAUDE.md
│   ├── rules/                      (8 룰 + INDEX)
│   ├── schemas/                    (7 SQL + INDEX)
│   └── screens/INDEX.md
└── reports/
    ├── CLAUDE.md
    ├── rules/                      (6 룰 + INDEX)
    ├── schemas/                    (5 SQL + INDEX)
    └── screens/INDEX.md
```

총: **78 파일** (CLAUDE.md 5 + 룰 32 + 스키마 30 + 화면 4 + 마이그 1 + 기타 6)

---

## 7. 통계 (현재 상태)

| 모듈 | 파일 | 라인 | 룰 ID | ENUM | 스키마 |
|---|---|---|---|---|---|
| payroll | 23 | 4,656 | EP-001~999 | (다수) | 10 |
| inventory | 19 | 2,876 | EI-001~999 | 16 | 8 |
| logistics | 18 | 3,110 | EL-001~999 | 13 | 7 |
| reports | 14 | 2,447 | ER-001~999 | 7 | 5 |
| **합계** | **74** | **13,089** | — | **36+** | **30** |

(CLAUDE.md 5개 추가 시 79 파일.)

---

## 8. 빠른 참조

- 각 모듈: `./payroll/CLAUDE.md`, `./inventory/CLAUDE.md`, `./logistics/CLAUDE.md`, `./reports/CLAUDE.md`
- 공통 룰 (예정): `../rules/permissions.md`, `../rules/integration.md`, `../rules/database.md`
- ERP Harness boilerplate (별도): `@erp-harness/core` v0.9.0
- Gridge AI MSP (별개 시스템): 본 ERP 와 데이터 / 권한 / 인프라 모두 분리

---

## 9. 다음 단계 (전 모듈 통합 작업)

| # | 작업 | 트리거 |
|---|---|---|
| 1 | **`rules/permissions.md`** — 4 모듈 권한 매트릭스 통합 | Phase 1 진입 전 필수 |
| 2 | **`rules/integration.md`** — 모든 PUB/SUB 이벤트 카탈로그 | 통합 |
| 3 | **`rules/database.md`** — DDL 규약 (NUMERIC / UUID / 인덱스) | 통합 |
| 4 | **Cross-module 마이그레이션 묶음** | inventory `RETURN`, items.weight/volume 등 |
| 5 | **Phase 0 boilerplate 갭 8개 작업** | outbox / ProcessedEvent / Saga 등 |
| 6 | **공통 스킬 정의** — designer / qa-engineer / frontend-developer | 화면 구현 진입 전 |
| 7 | **Phase 1 핵심 코드 구현** — 각 모듈 우선순위 핸들러 | Phase 1 본격 |
