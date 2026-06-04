# Logistics Screens — 인덱스 (프레임)

> **상위**: `../CLAUDE.md`
> **상태**: Phase 0 — 화면 ID + 라우팅 + 권한 매핑까지만. 실제 화면 / 디자인은 Phase 2+.
> **참조**: `../../../skills/designer/`, `../rules/INDEX.md`

---

## 0. 적용 정책

`payroll/screens/INDEX.md`, `inventory/screens/INDEX.md` 와 동일 — 화면 ID + 의도만 정의.

---

## 1. 화면 ID 네임스페이스

화면 ID = `ELS-xxx` (Logistics Screens). 룰 ID (EL-xxx) 와 구분.

| 범위 | 주제 | 우선순위 |
|---|---|---|
| ELS-001~049 | 기사 본인 (모바일 우선) | P0 |
| ELS-100~149 | 배송 관리 / 배차 (L3 / L4) | P0 |
| ELS-150~199 | 배송 추적 / 모니터링 | P0 |
| ELS-200~249 | 경로 / 묶음 배송 | P1 |
| ELS-300~349 | 기사 / 차량 마스터 | P0 |
| ELS-350~399 | 면허 / 보험 만료 알림 | P1 |
| ELS-400~449 | POD 조회 / 검증 | P1 |
| ELS-500~549 | 운임 단가 / 정산 | P1 |
| ELS-600~649 | 반품 / 회수 처리 | P0 (전자상거래) |
| ELS-700~749 | 외부 carrier 연동 / 설정 | P2 |
| ELS-800~849 | 보고서 / 대시보드 | P2 |
| ELS-900~949 | Super 관리 (마스터 / feature flag) | P2 |

---

## 2. 화면 목록

### 2.1 기사 본인 (모바일 우선)

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-001 | 오늘의 배송 (route 또는 단일) | `/me/deliveries/today` | EL-220, EL-080 |
| ELS-002 | 배송 상세 (수령자 PII 풀 — 진행 중만) | `/me/deliveries/[id]` | EL-070, EL-385 |
| ELS-003 | 출발 (IN_TRANSIT 전이) | `/me/deliveries/[id]/dispatch` | EL-020, EL-040 |
| ELS-004 | 도착 / 수령 (POD 등록) | `/me/deliveries/[id]/complete` | EL-320, EL-330 |
| ELS-005 | 사인 캡처 | `/me/deliveries/[id]/signature` | EL-325 |
| ELS-006 | 사진 캡처 (수령자 + 패키지) | `/me/deliveries/[id]/photo` | EL-325 |
| ELS-007 | 실명확인 (의약품 / 주류) | `/me/deliveries/[id]/id-verify` | EL-340, EL-345 |
| ELS-008 | 배송 실패 / FAILED | `/me/deliveries/[id]/fail` | EL-055 |
| ELS-009 | 본인 위치 동의 / 변경 | `/me/profile/location-consent` | EL-080 |

### 2.2 배송 관리 / 배차

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-100 | 배송 대시보드 (status 별) | `/admin/logistics/deliveries` | EL-020 |
| ELS-110 | 배송 생성 (수동) | `/admin/logistics/deliveries/new` | EL-010, EL-030 |
| ELS-120 | 배차 (driver / vehicle) | `/admin/logistics/deliveries/[id]/assign` | EL-150, EL-160 |
| ELS-130 | 배송 취소 | `/admin/logistics/deliveries/[id]/cancel` | EL-050 |
| ELS-140 | 배송 강제 상태 변경 (Super) | `/super/logistics/deliveries/[id]/force` | EL-090 |

### 2.3 배송 추적 / 모니터링

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-150 | 실시간 추적 지도 | `/admin/logistics/tracking-map` | EL-310 |
| ELS-160 | 배송별 이벤트 타임라인 | `/admin/logistics/deliveries/[id]/timeline` | EL-310 |
| ELS-170 | 지연 / SLA 위반 알림 | `/admin/logistics/sla-violations` | EL-260 |
| ELS-180 | 외부 carrier 콜백 로그 | `/admin/logistics/carrier-callbacks` | EL-635 |

### 2.4 경로 / 묶음 배송

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-200 | 경로 목록 | `/admin/logistics/routes` | EL-220 |
| ELS-210 | 경로 생성 / 편집 (PLANNED) | `/admin/logistics/routes/new` | EL-210 |
| ELS-220 | 자동 최적화 (외부 API) | `/admin/logistics/routes/[id]/optimize` | EL-230 |
| ELS-230 | 경로 시작 (IN_PROGRESS) | `/admin/logistics/routes/[id]/start` | EL-225 |
| ELS-240 | IN_PROGRESS 변경 / skip | `/admin/logistics/routes/[id]/edit-running` | EL-255 |

### 2.5 기사 / 차량 마스터

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-300 | 기사 목록 | `/admin/logistics/drivers` | EL-110 |
| ELS-310 | 기사 등록 / 수정 | `/admin/logistics/drivers/new` | EL-110 |
| ELS-315 | 기사 면허 정보 수정 (L4) | `/admin/logistics/drivers/[id]/license` | EL-150 |
| ELS-320 | 차량 목록 | `/admin/logistics/vehicles` | EL-130 |
| ELS-330 | 차량 등록 / 수정 | `/admin/logistics/vehicles/new` | EL-130, EL-135 |
| ELS-340 | 차량 보험 / 검사 (L4) | `/admin/logistics/vehicles/[id]/insurance` | EL-150 |

### 2.6 만료 / 알림

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-350 | 만료 임박 대시보드 (30/14/7/1일) | `/admin/logistics/expiry-alerts` | EL-155 |
| ELS-360 | 만료된 기사 / 차량 (배차 차단) | `/admin/logistics/expired` | EL-150 |

### 2.7 POD 조회 / 검증

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-400 | POD 목록 (마스킹) | `/admin/logistics/pods` | EL-360 |
| ELS-410 | POD 상세 (사인 / 사진 / 실명) | `/admin/logistics/pods/[id]` | EL-355, EL-380 |
| ELS-420 | 사진 / 사인 다운로드 (signed URL) | `/admin/logistics/pods/[id]/asset/[type]` | EL-355 |
| ELS-430 | 실명확인 데이터 조회 (L4) | `/admin/logistics/pods/[id]/id-verify` | EL-348, EL-380 |

### 2.8 운임 / 정산

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-500 | 단가표 일람 | `/admin/logistics/tariffs` | EL-410 |
| ELS-510 | 단가 신규 / 변경 (새 row) | `/admin/logistics/tariffs/new` | EL-415 |
| ELS-520 | 도서산간 surcharge | `/admin/logistics/region-surcharges` | EL-430 |
| ELS-530 | 배송별 운임 산정 결과 | `/admin/logistics/deliveries/[id]/cost` | EL-420 |
| ELS-540 | 월간 정산 (Phase 1+) | `/admin/logistics/settlements` | EL-440 |

### 2.9 반품 / 회수

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-600 | 반품 요청 목록 | `/admin/logistics/returns` | EL-520 |
| ELS-610 | 반품 요청 (고객 셀프) | `/customer/returns/new` | EL-510, EL-535 |
| ELS-620 | 반품 승인 / 거부 | `/admin/logistics/returns/[id]/approve` | EL-525, EL-545 |
| ELS-630 | 검수 입력 | `/admin/logistics/returns/[id]/inspect` | EL-560 |
| ELS-640 | 환불 발행 | `/admin/logistics/returns/[id]/refund` | EL-570, EL-575 |
| ELS-645 | 청약철회 7일 초과 예외 승인 (L4) | `/admin/logistics/returns/[id]/regret-override` | EL-535 |

### 2.10 외부 carrier 연동

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-700 | carrier 활성화 / 비활성화 | `/admin/logistics/carriers` | EL-615 |
| ELS-710 | API 키 / 시크릿 (Super) | `/super/logistics/carrier-secrets` | EL-695 |
| ELS-720 | 콜백 로그 / 재처리 (Super) | `/super/logistics/carrier-callbacks` | EL-635 |

### 2.11 보고서

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-800 | 일별 / 월별 배송 통계 | `/admin/logistics/reports/volume` | — |
| ELS-810 | 기사별 성과 (배송 건수 / 시간) | `/admin/logistics/reports/driver-perf` | — |
| ELS-820 | 반품률 / 사유별 | `/admin/logistics/reports/returns` | — |
| ELS-830 | SLA 준수율 | `/admin/logistics/reports/sla` | EL-260 |

### 2.12 Super 관리

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ELS-900 | feature flag 매트릭스 | `/super/logistics/feature-flags` | EL-910 |
| ELS-910 | feature flag 변경 (조직별) | `/super/logistics/feature-flags/[org]` | EL-940 |
| ELS-920 | PII 동의 이력 (조직 / 운전자) | `/super/logistics/consent-logs` | EL-365, EL-950 |
| ELS-930 | 위치 데이터 보존 / 삭제 (cron) | `/super/logistics/location-retention` | EL-075, EL-350 |
| ELS-940 | 강제 상태 변경 / audit | `/super/logistics/force-actions` | EL-090 |

---

## 3. 권한 매트릭스 (요약)

| 화면 그룹 | L1 (고객) | L2 (기사) | L3 | L4 | Super |
|---|---|---|---|---|---|
| ELS-001~009 (기사 본인) | ❌ | ✅ | ✅ | ✅ | ✅ |
| ELS-100~140 (배차) | ❌ | ❌ | ✅ | ✅ | ✅ |
| ELS-150~180 (추적) | ❌ | ✅ (본인) | ✅ | ✅ | ✅ |
| ELS-200~240 (경로) | ❌ | ✅ (본인) | ✅ | ✅ | ✅ |
| ELS-300~340 (마스터) | ❌ | ❌ | ✅ | ✅ | ✅ |
| ELS-350~360 (만료) | ❌ | ❌ | ✅ | ✅ | ✅ |
| ELS-400~430 (POD) | ❌ | ✅ (본인) | ⚠️ | ✅ | ✅ |
| ELS-500~540 (운임) | ❌ | ❌ | ✅ | ✅ | ✅ |
| ELS-600~640 (반품) | ✅ (본인 요청) | ❌ | ✅ | ✅ | ✅ |
| ELS-645 (예외 승인) | ❌ | ❌ | ❌ | ✅ | ✅ |
| ELS-700~720 (carrier) | ❌ | ❌ | ❌ (조회) | ✅ | ✅ |
| ELS-800~830 (보고서) | ❌ | ❌ | ✅ | ✅ | ✅ |
| ELS-900~940 (Super) | ❌ | ❌ | ❌ | ❌ | ✅ |

---

## 4. PII 마스킹 규칙 (UI 공통)

| 컬럼 | 표시 | 풀 보기 권한 |
|---|---|---|
| recipient_name | 홍** | 기사 (본인 진행 중), L3+ |
| recipient_phone | 010-****-1234 | 기사 (본인 진행 중), L3+ |
| recipient_address | 서울 강남구 *** | 기사 (본인 진행 중), L3+ |
| 사진 / 사인 | 흐림 / 일부 | L3+ (signed URL TTL 15분) |
| 실명확인 ID | 마스킹 (해시 표시) | L4+ |
| 운전자 위치 좌표 | 행정구역 단위만 | L4+ (해당 운전자 동의 시) |

---

## 5. 다음 단계 (Phase 2+)

1. 화면 ID 별 명세 파일 (`screens/ELS-XXX.md`) — 와이어프레임 / 컴포넌트 트리 / 인터랙션
2. 디자이너 에이전트 호출 — `skills/designer/prompts/`
3. frontend-developer 구현 — `skills/frontend-developer/`
4. QA 시나리오 — `skills/qa-engineer/scenarios/permission-matrix.md` Logistics 행 추가
5. 모바일 최적화 — ELS-001~009 는 PWA 우선, offline-first 검토

---

## 6. 참조

- 룰: `../rules/INDEX.md`
- 권한 매트릭스 상위: `../../../rules/permissions.md`
- 동일 패턴 모듈: `../../payroll/screens/INDEX.md`, `../../inventory/screens/INDEX.md`
