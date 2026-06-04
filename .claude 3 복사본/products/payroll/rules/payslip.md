# 명세서 (Payslip)

> **ID 범위**: EP-400 ~ EP-499
> **주제**: 급여명세서 발급 / 재발급 / 보관 / 교부
> **상위**: `INDEX.md`
> **기준법**: 근로기준법 §48 (임금명세서 교부 의무, 2021.11 시행)

---

## TL;DR

- **명세서 교부 = 법적 의무 (KR, MUST)**. 매 임금 지급 시 11개 필수 항목 명시. 위반 시 500만원 이하 과태료.
- **PDF 발급 = `payroll_records` 가 FINALIZED 된 후**. DRAFT 상태에서는 미리보기만, 정식 발급 금지.
- **명세서 자체는 `payroll_payslips` 테이블에 메타만 저장**. PDF 바이너리는 GCS / S3 (서명 URL 로 제공).
- **재발급 = 새 row + version++**. 기존 명세서 immutable.
- **수신 확인 (SHOULD)** — 본인이 열람 / 다운로드 시 audit. 미수신자는 추적 가능.
- **권한**: 본인 = 자기 명세서만, L3+ = 팀 명세서 (마스킹 해제), L4 = 전체.

핵심 ID: EP-410 (필수 항목) / EP-420 (PDF 발급) / EP-430 (재발급) / EP-450 (저장)

---

## 1. 법적 의무 (EP-400 ~ EP-409) — KR MUST

### EP-400. 임금명세서 교부 (MUST, KR)

근로기준법 §48 ②:
- 사용자는 임금을 지급할 때 **임금명세서를 서면 또는 전자적 방법**으로 교부해야 함.
- 위반 시 1차 30만원, 2차 50만원, 3차 100만원 과태료. 상한 500만원.

### EP-410. 필수 기재 11항목 (MUST, KR)

근로기준법 시행령 §27의2 ①:

1. 성명
2. 생년월일 / 사원번호 등 식별 정보
3. 임금 지급일
4. 임금 총액
5. 임금 구성항목별 금액 (기본급 / 각종 수당 / 상여금)
6. 임금 구성항목별 계산방법 (시간외 등은 산출식)
7. 공제 항목별 금액 / 총액
8. 출근일수 / 근로시간
9. 시간외 근로시간 (있을 경우)
10. 야간 / 휴일 근로시간 (있을 경우)
11. 근로일수 (일급제 / 시급제)

명세서 PDF / HTML 템플릿은 위 11항목을 **빠짐없이** 포함해야 함. 자동 검증:

```typescript
function validatePayslipFields(p: PayslipModel): void {
  const required = [
    'name', 'employeeNumber', 'paymentDate',
    'totalAmount', 'allowanceItems', 'allowanceCalcMethods',
    'deductionItems', 'attendanceDays', 'workedHours',
    // 조건부
    p.overtimeHours > 0 ? 'overtimeHours' : null,
    p.nightHours > 0 || p.holidayHours > 0 ? 'nightHolidayHours' : null,
    ['DAILY', 'HOURLY'].includes(p.scheme) ? 'workedDays' : null,
  ].filter(Boolean);
  for (const f of required) {
    if (p[f] == null) throw new MissingPayslipFieldError(f);
  }
}
```

### EP-411. 5인 미만 사업장도 의무 (MUST)

5인 미만 사업장도 명세서 교부 의무. 가산수당은 면제되어도 (EP-321) 명세서는 면제 없음.

### EP-415. 일용근로자 명세서 분기 (MUST, KR, v0.11)

일용근로자는 **두 가지 명세** 가 별개로 발생:

1. **임금명세서 (매 지급 시)** — 본 룰의 11항목 적용. 본인 교부.
2. **일용근로 지급명세서 (분기별)** — 국세청 신고용. 별도 양식. `day_laborer.md` § EP-770.

`payslip_type` 컬럼으로 구분:

| payslip_type | 용도 | 발급 시점 | 양식 |
|---|---|---|---|
| `REGULAR` | 일반 정규직 / 정기 명세서 | 월별 / 주별 | 사업장 표준 |
| `DAY_LABORER_SIMPLIFIED` | 일용직 본인 교부 (지급마다) | 매 지급 시 | 간략 (KR §48 11항목 충족) |
| `DAY_LABORER_QUARTERLY_REPORT` | 국세청 일용근로 지급명세서 | 분기 마지막 달 다음 달 말 | 시행규칙 별지 제24호 |

게이트: `payroll.day_laborer` 토글 ON 인 경우만 후 두 타입 활성화.

---

## 2. 발급 (EP-420 ~ EP-429)

### EP-420. PDF 발급 트리거 (MUST)

명세서는 `payroll_records.status = FINALIZED` 또는 `PAID` 일 때만 정식 발급:

```typescript
async function issuePayslip(recordId: string, actor: User): Promise<Payslip> {
  const record = await db.payrollRecord.findUnique({ where: { id: recordId }});
  if (!['FINALIZED', 'PAID'].includes(record.status)) {
    throw new InvalidStateError('FINALIZED 이후만 발급 가능');
  }
  // ...
}
```

### EP-421. DRAFT 단계는 미리보기만 (MUST)

DRAFT 상태에서는 화면 미리보기 (HTML preview) 만 제공. PDF 다운로드 / 이메일 발송 차단.

미리보기 응답에는 워터마크 ("DRAFT - 미확정") 명시.

### EP-422. PDF 생성 라이브러리 (SHOULD)

- 한글 폰트 임베디드 (Pretendard / Noto Sans KR 등)
- A4 1페이지 권장 (보통 직원은 1페이지에 수렴)
- @react-pdf/renderer 또는 puppeteer (선호 미정, Phase 2+ 결정)

### EP-423. PDF 메타데이터 포함 (MUST)

PDF 메타에 다음 포함:
- Title: `급여명세서_{userName}_{month}`
- Author: 사업장명
- Subject: 임금명세서
- Producer: ERP Harness
- 생성 시각

위변조 식별 / 검색 용이.

---

## 3. 저장 / 보관 (EP-430 ~ EP-449)

### EP-430. payroll_payslips 모델 (MUST)

PDF 바이너리는 GCS / S3, 메타만 DB:

```sql
CREATE TABLE payroll_payslips (
  id              UUID PRIMARY KEY,
  record_id       UUID NOT NULL,                     -- FK to payroll_records
  user_id         UUID NOT NULL,
  month           CHAR(7) NOT NULL,
  version         INTEGER NOT NULL DEFAULT 1,
  storage_path    VARCHAR(500) NOT NULL,             -- gs://bucket/... or s3://...
  storage_provider VARCHAR(20) NOT NULL,             -- 'gcs' / 's3'
  file_size       INTEGER NOT NULL,
  sha256          CHAR(64) NOT NULL,                 -- 무결성 검증
  issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  issued_by       UUID NOT NULL,
  delivery_status VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING / DELIVERED / FAILED
  delivered_at    TIMESTAMPTZ,
  acknowledged_at TIMESTAMPTZ,                       -- 본인 열람 시점
  notes           TEXT,
  UNIQUE (record_id, version)
);
```

### EP-431. SHA-256 무결성 (MUST)

PDF 생성 시 SHA-256 계산 → DB 저장. 다운로드 시 재검증 (선택). 위변조 탐지.

### EP-432. 저장 경로 패턴 (SHOULD)

`{provider}://{bucket}/payslips/{org_id}/{year}/{month}/{user_id}/v{version}.pdf`

조직별 / 연월별 디렉터리. 백업 / 삭제 정책 적용 용이.

### EP-435. 보관 기간 (MUST, KR)

근로기준법 §42 — 임금대장은 **3년 보관**. 명세서도 동일 기준 적용.

3년 경과 시:
- DB row 는 유지 (검색 / 감사용)
- PDF 바이너리는 삭제 가능 (단, 사업장 정책에 따라 5~10년 보관 권장)
- 삭제 시 `storage_path = NULL`, `notes = '보관 기간 만료 삭제'`

### EP-440. 서명 URL (MUST)

PDF 다운로드는 사전 서명 URL (signed URL):
- 만료 시간 5~15분
- 사용자별 / 1회용 권장
- 서명 URL 발급 시 audit (`payroll.payslip.url_issued`)

```typescript
async function getDownloadUrl(payslip: Payslip, actor: User): Promise<string> {
  await checkPayslipReadPermission(actor, payslip);
  const url = await storage.getSignedUrl(payslip.storagePath, { expiresIn: 600 });
  await writeAudit({
    actor: actor.id,
    action: 'payroll.payslip.url_issued',
    target: payslip.id,
    targetType: 'payslip',
    metadata: { recordId: payslip.recordId, expiresIn: 600 }
  });
  return url;
}
```

---

## 4. 재발급 / 정정 (EP-450 ~ EP-459)

### EP-450. 재발급 (MUST)

기존 명세서는 **수정 금지**. 재발급은 새 version row INSERT:

```typescript
async function reissuePayslip(recordId: string, reason: string, actor: User) {
  const last = await db.payrollPayslip.findFirst({
    where: { recordId },
    orderBy: { version: 'desc' }
  });
  const newVersion = (last?.version ?? 0) + 1;
  // 새 PDF 생성 + INSERT
  await db.payrollPayslip.create({
    data: { recordId, version: newVersion, ... }
  });
  await writeAudit({ action: 'payroll.payslip.reissued', metadata: { reason, replaces: last?.id }});
}
```

### EP-451. 재발급 사유 (MUST)

재발급은 다음 케이스에 한정:
- 정정 (계산 오류 발견 + record 가 새 version 으로 교체됨)
- 기재 누락 (필수 11항목 중 일부)
- 본인 분실 / 재요청

`payslip.notes` 또는 audit metadata 에 사유 명시.

### EP-455. 무효화 / 회수 (MAY)

부득이한 경우 기존 명세서를 회수해야 하면 별도 `voided_at` / `voided_reason` 필드 추가 (Phase 2+). 현재 v0.9 는 supersede (새 version 발급) 패턴만.

---

## 5. 교부 / 수신 확인 (EP-460 ~ EP-469)

### EP-460. 교부 방법 (MUST, KR)

- 전자문서 교부 (이메일 / 사내 시스템 다운로드) 가능
- 단, 근로자가 **종이 출력본을 요청**하면 거부 불가

따라서 시스템은 **PDF 자동 발송** + **종이 출력 요청 처리** 양쪽 지원.

### EP-461. 이메일 발송 (SHOULD)

발급 직후 이메일 자동 발송:
- 본문에 직접 PDF 첨부 X (보안)
- 대신 만료 24h 서명 URL 또는 사내 시스템 로그인 안내

### EP-462. 수신 확인 (SHOULD)

본인이 명세서 다운로드 / 열람 시 `acknowledged_at` 갱신. 미수신자는 30일 후 알림 / 재발송.

```typescript
async function recordAcknowledged(payslipId: string, actor: User) {
  await db.payrollPayslip.update({
    where: { id: payslipId },
    data: { acknowledgedAt: new Date() }
  });
  await writeAudit({ action: 'payroll.payslip.acknowledged', target: payslipId });
}
```

---

## 6. 권한 (EP-480 ~ EP-489)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 명세서 조회 (마스킹 해제) | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| 본인 명세서 다운로드 | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| 팀원 명세서 조회 (마스킹) | ❌ | ❌ (금액 마스킹 강제) | ✅ | ✅ | ⚠️ |
| 팀원 명세서 다운로드 (원본) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 발급 실행 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 재발급 (정정) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 보관 기간 만료 삭제 | ❌ | ❌ | ❌ | ❌ | ✅ (감사) |

> ⚠️ L2 는 본인 명세서 외에 팀원 명세서를 다운로드할 수 없다 (급여액 노출 차단).

---

## 7. 감사 (EP-490 ~ EP-499)

### EP-490. 필수 audit 액션

| action | 시점 |
|---|---|
| `payroll.payslip.issued` | 정식 발급 |
| `payroll.payslip.reissued` | 재발급 |
| `payroll.payslip.url_issued` | 서명 URL 발급 |
| `payroll.payslip.acknowledged` | 본인 수신 확인 |
| `payroll.payslip.viewed_by_other` | 본인 외 사용자가 열람 |
| `payroll.payslip.archived` | 보관 기간 만료 삭제 |

### EP-491. 본인 외 열람은 항상 감사 (MUST)

L3 / L4 / Super 가 팀원 명세서 열람 시 `payroll.payslip.viewed_by_other` 기록. metadata 에 viewer / target / 사유 (UI 에서 입력 강제).

---

## 8. 참조

- 임금명세서 양식: 고용노동부 표준 양식 (검색 시 매년 업데이트 확인)
- 다음: 지급 → `payment.md`
- 스키마: `../schemas/tables/payroll_payslips.sql` (Phase 1+ 추가)
