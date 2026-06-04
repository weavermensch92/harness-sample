# 보고서 정의 (Report Definition)

> **ID 범위**: ER-001 ~ ER-099
> **주제**: 보고서 메타 (이름 / 데이터 소스 / 파라미터 / 권한 / 출력)
> **상위**: `INDEX.md`

---

## TL;DR

- **report_definition = 메타 데이터** — 코드 / 이름 / 모듈 / 파라미터 스키마 / 권한 요구 / 출력 형식.
- **Built-in vs Custom** — KR 법정 보고서 (`KR_*` 코드) 는 코드 내장, 커스텀은 DB 정의 (Phase 1+).
- **데이터 소스 = 모듈 1개 이상** — `payroll`, `inventory`, `logistics`, 또는 통합. 권한 위임 정책의 기반.
- **파라미터 스키마** — JSON Schema 로 정의. 실행 시 검증.
- **권한 메타 (MUST)** — 각 보고서가 요구하는 모듈별 최소 권한 등급. 실행자가 부족하면 거부.
- **PII 매트릭스 (MUST)** — 보고서가 노출하는 PII 컬럼 명시. 권한별 마스킹 / 풀 표시 규칙.
- **변경 = 새 row + 버전** — 정의 변경 시 새 row, 기존은 active=false. 결과는 정의 버전 보존.

핵심 ID: ER-010 (모델) / ER-040 (KR 법정) / ER-060 (파라미터) / ER-080 (권한) / ER-090 (PII)

---

## 1. 모델 (ER-001 ~ ER-019)

### ER-010. report_definitions 테이블 (MUST)

```sql
CREATE TABLE report_definitions (
  id              UUID PRIMARY KEY,
  organization_id UUID,                            -- NULL = 전사 (built-in)
  code            VARCHAR(80) NOT NULL,            -- 'KR_PAYROLL_INSURANCE' / 'CUSTOM_xxx'
  name            VARCHAR(200) NOT NULL,
  description     TEXT,

  -- 데이터 소스
  source_modules  TEXT[] NOT NULL,                 -- ['payroll'] or ['payroll', 'logistics']
  data_query_kind VARCHAR(20) NOT NULL,            -- BUILTIN / SQL / API
  -- BUILTIN: 코드 내장 (typesafe). SQL: SELECT 문. API: 외부 호출.

  -- 파라미터 스키마 (JSON Schema)
  parameters_schema JSONB,                         -- e.g., { period_year: int, period_month: int }

  -- 권한 메타 (ER-080)
  required_permissions JSONB NOT NULL,             -- { payroll: 'L3', inventory: 'L3' }

  -- PII 메타 (ER-090)
  pii_columns     JSONB,                           -- [{ column, mask_rule }]

  -- 출력
  output_formats  TEXT[] NOT NULL DEFAULT ARRAY['xlsx', 'csv'],
  default_format  VARCHAR(10) NOT NULL DEFAULT 'xlsx',

  -- 버전 / 활성
  version         SMALLINT NOT NULL DEFAULT 1,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  is_builtin      BOOLEAN NOT NULL DEFAULT FALSE,  -- 코드 내장 여부

  -- 메타
  meta            JSONB,
  created_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (organization_id, code, version)
);
```

### ER-015. 정의 변경 = 새 row + 버전 (MUST)

기존 정의 변경 시 UPDATE 금지:
```typescript
async function updateDefinition(id, changes, actor) {
  await db.$transaction(async (tx) => {
    const old = await tx.reportDefinition.findUnique({ where: { id }});
    await tx.reportDefinition.update({ where: { id }, data: { isActive: false }});
    await tx.reportDefinition.create({
      data: { ...old, ...changes, version: old.version + 1, isActive: true, id: undefined }
    });
  });
}
```

> 과거 결과는 당시 정의 버전 참조 (`report_runs.definition_version`).

---

## 2. Built-in vs Custom (ER-020 ~ ER-039)

### ER-020. 결정 기준 (MUST)

| 종류 | 정의 위치 | 쿼리 위치 | 권한 / PII 메타 |
|---|---|---|---|
| BUILTIN | DB row + 코드 (`is_builtin=true`) | TypeScript 함수 | 코드에서 검증 |
| SQL | DB row 만 | DB row.query (SQL 문) | DB row 메타 |
| API | DB row 만 | 외부 URL / config | DB row 메타 |

KR 법정 보고서 (`KR_*`) 는 **무조건 BUILTIN**. 변동성 적고 정합성 중요.

### ER-025. BUILTIN 등록 (MUST, 시드)

```typescript
// business/reports/builtin/index.ts
export const BUILTIN_REPORTS: BuiltinReport[] = [
  {
    code: 'KR_PAYROLL_INSURANCE',
    name: '4대보험 신고자료',
    sourceModules: ['payroll'],
    parametersSchema: { period_year: 'integer', period_month: 'integer' },
    requiredPermissions: { payroll: 'L3' },
    piiColumns: [{ column: 'employee_name', maskRule: 'lastnameOnly' }],
    outputFormats: ['xlsx', 'csv'],
    handler: generateKrPayrollInsurance
  },
  // ...
];
```

DB 시드 시점에 INSERT (`is_builtin=true, organization_id=NULL`).

---

## 3. SQL 쿼리 정의 (ER-030 ~ ER-039) — Phase 1+

### ER-030. SQL 보안 (MUST, Phase 1+)

커스텀 SQL 정의 시:
- 읽기 전용 트랜잭션
- 별도 DB 사용자 (read-only)
- timeout 30초 강제
- 파라미터는 prepared statement (SQL injection 방어)

### ER-035. SQL Builder (Phase 2+)

비기술 사용자용 GUI builder. 위에서 안전 SQL 생성. (Phase 0 X)

---

## 4. KR 법정 보고서 (ER-040 ~ ER-059) — MUST

### ER-040. KR_PAYROLL_INSURANCE — 4대보험 신고

소스: payroll
- 입력: period_year, period_month
- 출력 컬럼: 사업장 / 사번 / 이름 / 급여 / 국민연금 / 건강보험 / 고용보험 / 산재 / 합계
- 형식: 4대보험공단 (NPS / NHIS / EI / KCOMWEL) 표준 양식 (xlsx)
- 권한: `payroll.L3`
- PII: 이름 (마스킹 옵션), 사번 (풀)

### ER-042. KR_PAYROLL_WITHHOLDING — 원천세 신고

소스: payroll
- 입력: period_year, period_month
- 출력 컬럼: 사번 / 이름 / 총지급액 / 비과세 / 과세 / 소득세 / 지방소득세 / 합계
- 형식: 국세청 홈택스 표준 양식 (xlsx, 텍스트 변환)
- 권한: `payroll.L3`
- PII: 이름 (마스킹 옵션), 사번 (풀)

### ER-044. KR_PAYROLL_DAY_LABORER_Q — 일용근로자 분기 신고

소스: payroll
- 입력: period_year, period_quarter
- 출력 컬럼: 사번 / 이름 / 분기내 근무일수 / 일당 합계 / 소액부징수 적용 여부 / 원천세
- 형식: 국세청 표준 (분기 신고)
- 권한: `payroll.L3`

### ER-046. KR_INVENTORY_VALUATION — 재고 평가 (K-IFRS)

소스: inventory
- 입력: snapshot_date, valuation_method (FIFO / MOVING_AVG)
- 출력 컬럼: 품목 / 카테고리 / 창고 / 잔고 / 단가 / 평가액 / 평가감 / 순평가액
- 형식: K-IFRS §2.9 양식 (xlsx)
- 권한: `inventory.L3`

### ER-048. KR_FINANCIAL_CLOSING_MONTHLY — 월결산

소스: payroll + inventory + logistics
- 입력: period_year, period_month
- 출력: 매출원가 / 인건비 / 운임 / 재고 변동 / 월결산 시트
- 형식: 통합 xlsx (회계 모듈 연동 시 더 풍부)
- 권한: `payroll.L4 AND inventory.L4 AND logistics.L3`

> 통합 보고서 — 모든 모듈 권한 충족 필요 (ER-080).

---

## 5. 파라미터 (ER-060 ~ ER-079)

### ER-060. JSON Schema (MUST)

```jsonc
{
  "type": "object",
  "required": ["period_year", "period_month"],
  "properties": {
    "period_year":  { "type": "integer", "minimum": 2020, "maximum": 2100 },
    "period_month": { "type": "integer", "minimum": 1,    "maximum": 12   },
    "facility_id":  { "type": "string",  "format": "uuid" }
  }
}
```

실행 전 ajv / zod 등으로 검증. 실패 시 4xx.

### ER-065. 시간 파라미터 표준 (MUST)

| 종류 | 입력 키 | 형식 |
|---|---|---|
| 월 | `period_year`, `period_month` | int |
| 분기 | `period_year`, `period_quarter` | int (1~4) |
| 일 | `snapshot_date` | YYYY-MM-DD |
| 범위 | `start_date`, `end_date` | YYYY-MM-DD |

조직 timezone (Asia/Seoul 기본) 기준 — 결과에 timezone 명시.

### ER-070. 파라미터 PII 마스킹

`facility_id`, `team_id`, `user_id` 등 입력 자체는 PII 아니지만, 좁힐수록 결과의 PII 가 식별 가능 — 권한 검증에 사용.

---

## 6. 권한 위임 (ER-080 ~ ER-089) — MUST

### ER-080. 권한 = 모든 모듈 권한 합집합 (MUST)

```typescript
async function checkReportPermission(definition, actor) {
  for (const [module, requiredLevel] of Object.entries(definition.requiredPermissions)) {
    const actorLevel = await getUserLevel(actor, module);
    if (compareLevel(actorLevel, requiredLevel) < 0) {
      throw new InsufficientPermissionError({
        module, required: requiredLevel, actual: actorLevel
      });
    }
  }
}
```

예: `KR_FINANCIAL_CLOSING_MONTHLY` (`payroll.L4 AND inventory.L4 AND logistics.L3`):
- L3 은 logistics 만 충족 → 거부
- payroll.L4 + inventory.L3 + logistics.L4 → 거부 (inventory L4 필요)

### ER-085. 조직 / 시설 스코프 검증 (MUST)

actor 가 다른 조직의 보고서 실행 X. 시설별 권한도 검증:
- 조직 A 의 사용자 + 조직 B 의 보고서 = 거부
- 시설 X 권한만 있는 사용자가 모든 시설 보고서 = 시설 X 데이터만 필터링 또는 거부

---

## 7. PII 매트릭스 (ER-090 ~ ER-099) — MUST

### ER-090. 컬럼별 마스킹 규칙 (MUST)

```jsonc
"pii_columns": [
  { "column": "employee_name",   "mask_rule": "lastnameOnly",        "unmask_level": "L4" },
  { "column": "employee_ssn",    "mask_rule": "hash",                "unmask_level": "Super" },
  { "column": "employee_account","mask_rule": "last4",               "unmask_level": "L4" },
  { "column": "recipient_phone", "mask_rule": "middle4",             "unmask_level": "L3" },
  { "column": "recipient_address","mask_rule": "districtOnly",       "unmask_level": "L3" }
]
```

### ER-095. 마스킹 적용 (MUST)

생성 시 항상 마스킹 컬럼과 풀 컬럼 둘 다 결과에 보존:
- L3 결과: 마스킹 컬럼만 표시
- L4 결과: 풀 컬럼 표시 (UI 토글)
- 다운로드 / 이메일: 권한별 다른 파일 (마스킹 / 풀)

```typescript
function applyMasking(rows, piiColumns, actorLevel) {
  return rows.map(row => {
    const masked = { ...row };
    for (const col of piiColumns) {
      if (compareLevel(actorLevel, col.unmask_level) < 0) {
        masked[col.column] = applyMaskRule(row[col.column], col.mask_rule);
      }
    }
    return masked;
  });
}
```

### ER-098. 외부 배포 시 PII (MUST)

이메일 / API 외부 노출:
- 기본 마스킹 (L3 수준)
- 풀 PII 외부 노출 = 별도 권한 + audit + 수신자 검증

---

## 8. 권한 / 감사

(ER-080 권한은 위에서 다룸. 감사는 `report_generation.md` ER-180 에서 통합.)

---

## 9. 참조

- 게이트: `feature_flags.md` (`report.kr_legal_pack`)
- 실행: `report_generation.md` (ER-100~)
- 스케줄: `scheduling.md` (ER-200~)
- 배포: `distribution.md` (ER-300~)
- 스키마: `../schemas/tables/report_definitions.sql`
- 데이터 소스 모듈: `../../payroll/rules/INDEX.md`, `../../inventory/rules/INDEX.md`, `../../logistics/rules/INDEX.md`
