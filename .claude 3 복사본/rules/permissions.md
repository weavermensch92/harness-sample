# 권한 매트릭스 (Permissions)

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (4-모듈 통합)
> **참조**: 각 모듈 `rules/INDEX.md`, `screens/INDEX.md`

---

## 0. 적용 범위

이 문서는 **payroll / inventory / logistics / reports** 4 모듈의 권한 매트릭스를 통합한다. 각 모듈 룰의 권한 섹션은 이 문서의 등급 정의를 준수한다.

이 문서는 **읽기 / 쓰기 / 승인 / 외부 노출** 4 차원의 권한을 다룬다. 데이터 자체의 PII 마스킹은 별도 (각 룰 PII 섹션 참조).

---

## 1. 권한 등급 (Levels)

### 1.1 등급 정의

| 등급 | 이름 | 스코프 | 일반적 역할 |
|---|---|---|---|
| **L1** | Self | 본인 | 일반 사용자 (고객 / 구성원) — 본인 데이터만 |
| **L2** | Field | 본인 + 직접 작업 | 현장 작업자 (기사 / 창고 직원 / 배송 기사) |
| **L3** | Facility | 시설 / 사업장 | 시설장 / 매장 매니저 / 팀 리드 |
| **L4** | Organization | 조직 전체 | 본부장 / CFO / 인사 책임자 |
| **L5** | Multi-org (예약) | 다(多) 조직 | (Phase 2+) 그룹 / 지주 / MSP 운영 |
| **Super** | System Admin | 시스템 전체 | Anthropic / Gridge 운영 — 전사 관리 / 시스템 정합 |

### 1.2 등급 비교 함수 (MUST)

```typescript
const LEVEL_ORDER = ['L1', 'L2', 'L3', 'L4', 'L5', 'Super'] as const;
type Level = typeof LEVEL_ORDER[number];

function compareLevel(a: Level, b: Level): number {
  return LEVEL_ORDER.indexOf(a) - LEVEL_ORDER.indexOf(b);
}

function meetsLevel(actor: Level, required: Level): boolean {
  return compareLevel(actor, required) >= 0;
}
```

### 1.3 사용자별 등급 (MUST)

한 사용자는 모듈별 / 시설별 다른 등급을 가질 수 있다:

```typescript
interface UserPermissions {
  userId: string;
  organizationId: string;
  perModule: {
    payroll?:   { level: Level; facilityScope?: string[] };
    inventory?: { level: Level; facilityScope?: string[] };
    logistics?: { level: Level; facilityScope?: string[] };
    reports?:   { level: Level; facilityScope?: string[] };
  };
}
```

예:
- 매장 매니저: `payroll: L3 (시설 X)`, `inventory: L3 (시설 X)`, `logistics: L2`, `reports: L3`
- 본부 CFO: `payroll: L4`, `inventory: L4`, `logistics: L3`, `reports: L4`
- 배송 기사: `logistics: L2`, 그 외 모듈 X

### 1.4 등급 부여 (MUST)

- L1 → 시스템 자동 (회원가입 / user 생성)
- L2 / L3 → L4 가 부여
- L4 → Super 가 부여
- Super → Anthropic / Gridge 내부 절차 (시스템 외부 + audit)

부여 변경은 모두 audit (`auth.permission.granted` / `revoked`).

---

## 2. 핵심 원칙 (모듈 전체 MUST)

### 2.1 권한 분리 (Segregation of Duties)

입력자 ≠ 승인자 — 사기 방지:

| 작업 | 입력자 | 승인자 |
|---|---|---|
| payroll 지급 (payment) | L3 | L4 |
| inventory 실사 (cycle_count) 차이 조정 | L2 / L3 | L3 / L4 |
| logistics 반품 환불 | L3 | L3 / L4 |
| logistics 청약철회 7일 초과 예외 승인 | (없음) | L4 |
| 마감 (period_closed / month_closed) | L3 (요청) | L4 (승인) |

같은 사용자가 입력 + 승인 시도 → 거부 + audit.

### 2.2 스코프 검증 (Scope Validation)

권한 등급뿐 아니라 **시설 / 팀 스코프** 검증:
- `facilityScope` 가 명시되면 그 시설 데이터만 접근
- 다른 시설 데이터 접근 시 거부 (또는 자동 필터)

```typescript
async function checkScope(actor, target) {
  if (target.facilityId && actor.facilityScope) {
    if (!actor.facilityScope.includes(target.facilityId)) {
      throw new ScopeViolationError();
    }
  }
}
```

### 2.3 보고서는 권한 합집합 (Reports AND)

reports 모듈 (ER-080) — 보고서 실행은 **모든 데이터 소스 모듈의 최소 등급 충족** 필요:

```typescript
async function checkReportPermission(definition, actor) {
  for (const [module, requiredLevel] of Object.entries(definition.requiredPermissions)) {
    const actorLevel = actor.perModule[module]?.level;
    if (!actorLevel || !meetsLevel(actorLevel, requiredLevel)) {
      throw new InsufficientPermissionError({ module, required: requiredLevel, actual: actorLevel });
    }
  }
}
```

### 2.4 Super 강제 액션은 강화 audit (MUST)

Super 등급의 비상 / 우회 액션:
- immutable run 강제 재생성
- 마감된 period 강제 재오픈
- API 시크릿 변경
- feature flag 시드 / 신규 등록

→ 일반 audit + 사유 텍스트 + Slack 알림 + 월간 리뷰.

### 2.5 외부 노출은 별도 검증 (MUST)

PII 풀 외부 발송 (이메일 / API):
- L4+ 권한 필요
- 화이트리스트 등록 필수
- 강화 audit (`*.full_pii_distributed`)

---

## 3. 모듈별 권한 매트릭스

### 3.1 Payroll

| 작업 (룰 ID) | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 출퇴근 등록 (EP-010) | ✅ | ✅ | ✅ | ✅ | ✅ |
| 본인 work_log 조회 (EP-100) | ✅ | ✅ | ✅ | ✅ | ✅ |
| 본인 명세서 조회 (EP-410) | ✅ | ✅ | ✅ | ✅ | ✅ |
| 팀원 출퇴근 보정 (EP-040) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| work_log 입력 / 수정 (EP-130) | ❌ | ✅ (본인) | ✅ | ✅ | ⚠️ |
| 급여 산정 실행 (EP-200) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 공제 항목 변경 (EP-378) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 명세서 발급 (EP-415) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 명세서 발송 (이메일) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **payment 입력** (EP-510) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **payment 승인** (EP-510-A) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| period 마감 요청 (EP-580) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **period 마감 승인** | ❌ | ❌ | ❌ | ✅ | ✅ |
| compensation_settings 변경 (새 row) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 일용근로자 등록 (EP-710) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| task_definitions 변경 (EP-812) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| feature_flags 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| 마감된 period 강제 재오픈 | ❌ | ❌ | ❌ | ❌ | ✅ + 강화 audit |

### 3.2 Inventory

| 작업 (룰 ID) | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 재고 조회 (EI-200) | — | ✅ | ✅ | ✅ | ✅ |
| 빠른 입고 / 출고 (현장) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| movement 등록 (EI-100) | ❌ | ⚠️ (현장) | ✅ | ✅ | ⚠️ |
| TRANSFER 등록 (EI-440) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| ADJUSTMENT 등록 (EI-121) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **REVERSAL** (정정) (EI-150) | ❌ | ❌ | ✅ | ✅ | ⚠️ + 사유 |
| item 마스터 등록 / 수정 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| lot 마스터 / 격리 (QUARANTINED) (EI-315) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 만료 폐기 처리 (EI-348) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 회수 (Recall) 추적 (EI-355) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 창고 등록 / FROZEN (EI-435) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **cycle_count 입력** (EI-520) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| **cycle_count 차이 조정** (EI-530) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **cycle_count 승인** | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 평가 단가 조회 | ❌ | ❌ | ✅ | ✅ | ✅ |
| 평가 보고서 조회 | ❌ | ❌ | ✅ | ✅ | ✅ |
| **저가법 평가감 승인** (EI-640) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| **평가 방법 변경** (EI-630) | ❌ | ❌ | ❌ | ❌ | ✅ + 회계 결산 |
| 마감일 (closed_period) 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| feature_flags 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| FIFO 레이어 직접 수정 | ❌ | ❌ | ❌ | ❌ | ⚠️ 비상시 |

### 3.3 Logistics

| 작업 (룰 ID) | L1 | L2 (기사) | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 배송 조회 (수령자) | ✅ | — | — | — | — |
| 본인 배정 delivery 조회 (기사) | — | ✅ | ✅ | ✅ | ✅ |
| Delivery 생성 (수동) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 배차 (ASSIGNED 전이) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 출발 (IN_TRANSIT, 본인 배송) (EL-020) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| **DELIVERED 전이 (POD 등록)** | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| FAILED 전이 | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 취소 (DRAFT / ASSIGNED 만) (EL-050) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 강제 상태 변경 | ❌ | ❌ | ❌ | ⚠️ | ✅ + audit |
| 수령자 PII 풀 조회 | ❌ | ✅ (배송 중만) | ✅ | ✅ | ✅ |
| driver 등록 / 수정 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **driver 면허 정보 수정** (EL-150) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| vehicle 등록 / 수정 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **vehicle 보험 / 검사 수정** | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 만료된 항목 강제 배차 | ❌ | ❌ | ❌ | ⚠️ + audit | ✅ |
| route 생성 / 자동 최적화 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| route IN_PROGRESS 변경 (EL-255) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| POD 등록 (driver) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| POD 풀 조회 (PII) | ❌ | ❌ | ⚠️ | ✅ | ✅ |
| 사진 / 사인 다운로드 | ❌ | ✅ (본인) | ⚠️ | ✅ | ✅ |
| 실명확인 데이터 조회 | ❌ | ❌ | ❌ | ✅ | ✅ |
| tariff 등록 / 변경 (EL-415) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **도서산간 surcharge 변경** | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| **정산 승인 (FINALIZED)** (EL-440) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 반품 요청 | ✅ (본인) | ❌ | ✅ | ✅ | ✅ |
| **반품 승인 / 거부** (EL-525) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 검수 입력 (RECEIVED) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| **환불 승인** (EL-570) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| **cost_bearer 변경** (EL-545) | ❌ | ❌ | ⚠️ | ✅ | ⚠️ |
| **청약철회 7일 초과 예외 승인** (EL-535) | ❌ | ❌ | ❌ | ✅ + audit | ✅ |
| carrier API 시크릿 조회 / 변경 | ❌ | ❌ | ❌ | ❌ | ✅ |
| carrier 어댑터 토글 | ❌ | ❌ | ❌ | ✅ | ✅ |
| feature_flags 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |

### 3.4 Reports

| 작업 (룰 ID) | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 / 팀 보고서 실행 | ❌ | ❌ | ✅ | ✅ | ✅ |
| 조직 전체 보고서 실행 | ❌ | ❌ | ⚠️ (정의별) | ✅ | ✅ |
| **풀 PII 결과 다운로드** (ER-175) | ❌ | ❌ | ❌ | ✅ | ✅ |
| 정의 신규 (커스텀, Phase 1+) | ❌ | ❌ | ⚠️ (조회) | ✅ | ✅ |
| BUILTIN 정의 변경 | ❌ | ❌ | ❌ | ❌ | ✅ |
| 스케줄 생성 / 수정 | ❌ | ❌ | ✅ | ✅ | ✅ |
| **스케줄 영구 비활성화** | ❌ | ❌ | ❌ | ✅ | ✅ |
| cron < 5 분 (예외) | ❌ | ❌ | ❌ | ❌ | ✅ |
| Email 수동 발송 (마스킹) | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Email 수동 발송 (풀 PII)** (ER-365) | ❌ | ❌ | ❌ | ✅ | ✅ |
| 화이트리스트 추가 / 제거 | ❌ | ❌ | ❌ | ✅ | ✅ |
| API 엔드포인트 등록 | ❌ | ❌ | ❌ | ❌ | ✅ |
| 자동 발송 schedule (마스킹만) | ❌ | ❌ | ✅ | ✅ | ✅ |
| **immutable run 강제 재생성** (ER-185) | ❌ | ❌ | ❌ | ❌ | ✅ + 강화 audit |
| **immutable run 강제 삭제** (ER-480) | ❌ | ❌ | ❌ | ❌ | ✅ + 강화 audit + 사유 |
| 보존 정책 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| audit log 조회 | ❌ | ❌ | ❌ | ✅ | ✅ |
| 데이터 주체 요청 처리 (Phase 1+) | ❌ | ❌ | ❌ | ✅ + audit | ✅ |
| feature_flags 변경 | ❌ | ❌ | ❌ | ✅ | ✅ |
| **외부 발송 토글** (email/api/slack) | ❌ | ❌ | ❌ | ⚠️ (검증 후) | ✅ |
| `kr_legal_pack` 시드 | ❌ | ❌ | ❌ | ❌ | ✅ |

---

## 4. PII 풀 조회 매트릭스

| PII 종류 | L1 (본인) | L2 | L3 | L4 | Super | 근거법 |
|---|---|---|---|---|---|---|
| 본인 정보 (모든 PII) | ✅ | — | — | — | — | 자기결정권 |
| 직원 이름 (성+이름) | — | 마스킹 | 풀 (팀) | 풀 | 풀 | 개인정보보호법 §15 |
| 직원 SSN (주민번호) | 본인 풀 | ❌ | 마스킹 (last4) | 마스킹 | 풀 | 개인정보보호법 §24-1 |
| 직원 계좌 번호 | 본인 풀 | ❌ | 마스킹 (last4) | 풀 | 풀 | 개인정보보호법 |
| 수령자 이름 | 본인 (배송중) | 풀 (본인 배송) | 풀 | 풀 | 풀 | 개인정보보호법 §15 |
| 수령자 전화 | 본인 (배송중) | 풀 (본인 배송) | 풀 | 풀 | 풀 | 개인정보보호법 |
| 수령자 주소 | 본인 (배송중) | 풀 (본인 배송) | 풀 (district) | 풀 | 풀 | 개인정보보호법 |
| 운전자 위치 좌표 | 본인 풀 | ❌ | district 단위 | 풀 (동의 시) | 풀 | 개인정보보호법 §15 (동의) |
| POD 사진 / 사인 | 본인 (다운) | 본인 배송 | 풀 (audit) | 풀 | 풀 | 개인정보보호법 |
| 실명확인 ID 데이터 | 본인 | ❌ | ❌ | 풀 (audit) | 풀 | 약사법 / 청소년보호법 |

마스킹 규칙:
- 이름: "홍**" (성 + 별표)
- 전화: "010-****-1234" (가운데 4자리)
- 주소: "서울특별시 강남구 ***" (상세 주소 마스킹)
- 좌표 district: 행정구역까지만 ("강남구")
- SSN: "*-****-1234" (last4)
- 계좌: "***-****-1234" (last4)

---

## 5. 마감 / Immutable 권한

| 작업 | 권한 | audit |
|---|---|---|
| period 마감 요청 (각 모듈) | L3+ | 일반 |
| **period 마감 승인** | L4+ | 일반 |
| 마감된 period 변경 | **불가** (Super 만) | 강화 + 사유 |
| **마감 강제 재오픈** | Super 만 | 강화 + 사유 + Slack 알림 + 월간 리뷰 |
| reports immutable run 재생성 | Super 만 | 강화 + 사유 |
| reports immutable run 삭제 | Super 만 | 강화 + 사유 + 데이터 주체 통보 |

마감 후 변경은 회계 / 세무 / 감사 위험 — 강제 변경은 항상 운영 절차 + 감사 추적.

---

## 6. 권한 부여 / 변경 / 회수

### 6.1 부여 흐름

```
신규 사용자 → L1 (자동)
       ↓
    L4 가 부여 (조직 내 L2 / L3)
       ↓
    Super 가 부여 (L4)
       ↓
    Anthropic / Gridge 내부 절차 (Super)
```

### 6.2 회수 (MUST)

- 사용자 비활성 / 퇴사 → 모든 권한 자동 회수
- 단, audit / 보존 의무 데이터는 보존
- 회수 시 진행 중인 작업 (예: PENDING report_run, ASSIGNED delivery) 처리:
  - 자동 reassign (가능 시) 또는 운영자 알림
  - delivery / payment 등 진행 중 → Super 가 강제 재배정

### 6.3 임시 권한 부여 (Phase 1+)

특정 시점 / 작업 한정 권한 (예: 외부 회계사 monthly close 임시 L4):
- TTL 명시 (만료 시점)
- 자동 회수
- 강화 audit

---

## 7. audit 로그 표준

### 7.1 컬럼 (MUST)

| 컬럼 | 의미 |
|---|---|
| `timestamp` | UTC, ms 정밀도 |
| `action` | 네임스페이스 (`{module}.{entity}.{verb}`) |
| `actor_user_id` | 행위자 (NULL 불가) |
| `actor_level` | 행위 시점 등급 |
| `target_type` | 대상 엔티티 (`payment`, `delivery`, `report_run` 등) |
| `target_id` | 대상 ID |
| `organization_id` | 조직 |
| `facility_id` | 시설 (옵션) |
| `metadata` | JSONB (사유 / 변경 전후 / IP / user_agent 해시) |
| `before_value` | 변경 전 상태 (JSONB) |
| `after_value` | 변경 후 상태 (JSONB) |

### 7.2 보존

- 일반: 5년
- 풀 PII 노출: 7년
- Super 강제 액션: 영구

### 7.3 수정 / 삭제 금지 (MUST)

```sql
REVOKE UPDATE, DELETE ON audit_logs FROM application_user;
```

또는 별도 시스템 (CloudWatch / Datadog / 자체 ledger).

---

## 8. 검증 헬퍼 (구현 가이드)

### 8.1 표준 헬퍼 (MUST)

```typescript
// 단일 모듈 권한
async function requirePermission(
  actor: User,
  module: ModuleName,
  level: Level,
  options?: { facilityId?: string; targetUserId?: string }
): Promise<void> {
  const perm = actor.perModule[module];
  if (!perm || !meetsLevel(perm.level, level)) {
    await writeAudit({
      action: `${module}.permission_denied`,
      actor: actor.id, metadata: { required: level, actual: perm?.level }
    });
    throw new InsufficientPermissionError(module, level);
  }
  if (options?.facilityId && perm.facilityScope) {
    if (!perm.facilityScope.includes(options.facilityId)) {
      throw new ScopeViolationError();
    }
  }
}

// 권한 분리 검증
async function requireDifferentApprover(
  actor: User,
  inputerId: string
): Promise<void> {
  if (actor.id === inputerId) {
    throw new SegregationOfDutiesError('입력자와 승인자는 같을 수 없습니다.');
  }
}
```

### 8.2 사용 예

```typescript
// payroll payment 승인
await requirePermission(actor, 'payroll', 'L4', { facilityId: payment.facilityId });
await requireDifferentApprover(actor, payment.inputerId);
await db.payment.update({ /* ... */ });
```

---

## 9. 미해결 / Phase 1+ 결정사항

- [ ] L5 (multi-org) 등급 — Phase 2 그룹사 / MSP 운영 시 정의
- [ ] 임시 권한 / TTL 부여 — Phase 1+
- [ ] 외부 감사인 임시 read-only — Phase 1+ (회계 결산)
- [ ] 권한 위임 (delegation) — 휴가 / 부재 시 임시 위임
- [ ] 다국어 권한 라벨 — 외국 직원 대응 (Phase 2+)

---

## 10. 참조

- 각 모듈 룰의 권한 섹션:
  - `../products/payroll/rules/*.md` § 권한 / 감사
  - `../products/inventory/rules/*.md` § 권한
  - `../products/logistics/rules/*.md` § 권한
  - `../products/reports/rules/*.md` § 권한
- 통합 룰: `./integration.md` (이벤트), `./database.md` (DB 규약)
- 한국 법령:
  - 개인정보보호법 §15 (수집 / 이용), §24-1 (주민번호), §29 (안전조치), §35 (데이터 주체 요청)
  - 근로기준법 §42 (보존 3년)
  - 약사법 §44 (의약품 본인 수령)
  - 청소년보호법 §28 (유해물품)
