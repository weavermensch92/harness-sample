# 갭 06 — PII 마스킹 자동 강제

> **버전**: v0.3 진입 시 구현
> **위치**: `@erp-harness/core` 의 `_shared/pii/` + ESLint 룰
> **영향**: 모든 모듈의 API 응답 / 이벤트 페이로드 / 로그 / audit
> **의존**: `.claude/rules/permissions.md` § 4 (PII 매트릭스)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- `permissions.md` § 4 에 PII 컬럼 매트릭스 정의 (이름 / 전화 / 주소 / SSN / 좌표 / 사진)
- 각 모듈 룰의 코멘트로 마스킹 / 등급 명시
- **코드 자동 강제 부재** — 핸들러 / 컨트롤러가 PII 컬럼을 그대로 응답에 포함하면 사고 발생
- 로그 / 외부 webhook 페이로드에 PII 노출 위험

### 영향

- 코드 review 만으로는 PII 누락 발견 어려움
- 신규 컬럼 추가 시 마스킹 정책 누락
- 외부 carrier / ESP webhook 에 PII 노출 사고 가능
- audit log / 메트릭에 PII 포함 시 GDPR / 개인정보보호법 위반

### 목표

- 컴파일 / 런타임 자동 검증 — PII 컬럼이 마스킹 없이 응답 / 로그에 노출 차단
- 데코레이터 + 정적 분석 (ESLint 룰) 결합
- 외부 노출 경로 (응답 / 이벤트 / 로그 / audit) 모두 커버

---

## 1. 인터페이스

```typescript
// business/_shared/pii/types.ts

export type MaskRule =
  | 'lastnameOnly'      // '홍길동' → '홍**'
  | 'middle4'           // '010-1234-5678' → '010-****-5678'
  | 'last4'             // '1234-5678-9012-3456' → '************-3456'
  | 'districtOnly'      // '서울 강남구 삼성로 ...' → '서울 강남구'
  | 'hash'              // SHA-256 hash (식별 불가)
  | 'redact';           // '***' 완전 가림

export interface PiiColumn {
  /** 컬럼 키 (응답 / 페이로드 / 로그 등) */
  key: string;
  /** 마스킹 규칙 */
  rule: MaskRule;
  /** 풀 PII 접근 가능 최소 등급 (`./permissions.md` § 1) */
  unmaskLevel: 'L3' | 'L4' | 'Super';
  /** 외부 노출 (이메일 / API webhook / Slack) 시 풀 허용 여부 — 기본 false */
  allowExternalFull?: boolean;
}

export interface PiiMaskingContext {
  actorMaxLevel: 'L1' | 'L2' | 'L3' | 'L4' | 'L5' | 'Super';
  isExternal: boolean;       // 외부 노출 (이메일 / API / 로그)?
  forceMasked?: boolean;     // 무조건 마스킹 (외부 발송 강제)
}
```

## 2. 핵심 구현

```typescript
// business/_shared/pii/masking.ts

const MASK_FNS: Record<MaskRule, (value: string) => string> = {
  lastnameOnly: (v) => v.length === 0 ? '' : v[0] + '*'.repeat(Math.max(1, v.length - 1)),
  middle4: (v) => {
    const parts = v.replace(/\D/g, '');
    if (parts.length < 8) return v;
    const len = parts.length;
    const middleStart = Math.floor((len - 4) / 2);
    return v.replace(/\d{4}/g, (match, idx) => idx === middleStart ? '****' : match);
  },
  last4: (v) => {
    const last = v.slice(-4);
    return '*'.repeat(Math.max(0, v.length - 4)) + last;
  },
  districtOnly: (v) => {
    // KR 주소: '시/도 + 구/군' 까지만
    const m = v.match(/^([^\s]+(?:특별시|광역시|특별자치시|특별자치도|도)?\s+[^\s]+(?:시|군|구))/);
    return m ? `${m[1]} ***` : v.split(/\s/).slice(0, 2).join(' ') + ' ***';
  },
  hash: (v) => 'hash:' + sha256(v).slice(0, 16),
  redact: () => '***'
};

export function maskValue(value: string | null | undefined, rule: MaskRule): string {
  if (value === null || value === undefined) return '';
  return MASK_FNS[rule](String(value));
}

export function applyMaskingToObject<T extends Record<string, any>>(
  obj: T,
  piiColumns: PiiColumn[],
  context: PiiMaskingContext
): T {
  const result: any = { ...obj };
  for (const col of piiColumns) {
    const value = result[col.key];
    if (value === undefined || value === null) continue;

    if (shouldMask(col, context)) {
      result[col.key] = maskValue(value, col.rule);
    }
  }
  return result;
}

export function shouldMask(col: PiiColumn, ctx: PiiMaskingContext): boolean {
  if (ctx.forceMasked) return true;

  // 외부 노출 시 — allowExternalFull 검증
  if (ctx.isExternal && !col.allowExternalFull) {
    return true;
  }

  // 등급 비교
  const levelOrder = ['L1', 'L2', 'L3', 'L4', 'L5', 'Super'];
  const actorIdx = levelOrder.indexOf(ctx.actorMaxLevel);
  const requiredIdx = levelOrder.indexOf(col.unmaskLevel);
  return actorIdx < requiredIdx;
}
```

## 3. 데코레이터 / 응답 변환

### 3.1 응답 미들웨어 (Express / Next API)

```typescript
// business/_shared/pii/response-mask.ts

/**
 * Route 단위 PII 보호 — 응답 직전에 마스킹 자동 적용
 */
export function withPiiProtection<TInput, TOutput extends object>(
  piiColumns: PiiColumn[],
  handler: (input: TInput, ctx: { actor: User }) => Promise<TOutput | TOutput[]>
) {
  return async (input: TInput, ctx: { actor: User }): Promise<TOutput | TOutput[]> => {
    const result = await handler(input, ctx);
    const maskingCtx: PiiMaskingContext = {
      actorMaxLevel: ctx.actor.maxLevel,
      isExternal: false
    };

    if (Array.isArray(result)) {
      return result.map(item => applyMaskingToObject(item, piiColumns, maskingCtx));
    }
    return applyMaskingToObject(result, piiColumns, maskingCtx);
  };
}
```

사용:

```typescript
// app/api/deliveries/[id]/route.ts
const DELIVERY_PII_COLUMNS: PiiColumn[] = [
  { key: 'recipientName', rule: 'lastnameOnly', unmaskLevel: 'L3' },
  { key: 'recipientPhone', rule: 'middle4', unmaskLevel: 'L3' },
  { key: 'recipientAddress', rule: 'districtOnly', unmaskLevel: 'L3' }
];

export const GET = withPiiProtection(DELIVERY_PII_COLUMNS, async (input, ctx) => {
  return await db.delivery.findUnique({ where: { id: input.id }});
});
```

### 3.2 외부 webhook / 이메일 발송 직전

```typescript
// business/_shared/pii/external.ts

export function maskForExternal<T extends object>(
  obj: T,
  piiColumns: PiiColumn[]
): T {
  return applyMaskingToObject(obj, piiColumns, {
    actorMaxLevel: 'L1',  // 외부 = 최소 등급 취급
    isExternal: true,
    forceMasked: true     // L4 라도 외부 노출 시 마스킹 (기본)
  });
}

// reports email distribution (ER-330) 사용
const masked = maskForExternal(reportRow, REPORT_PII_COLUMNS);
await sendEmail({ ..., body: render(masked) });
```

## 4. 로그 / audit 마스킹

```typescript
// business/_shared/pii/logging.ts

/**
 * logger 의 부가 데이터에서 PII 자동 마스킹
 */
export function safeLog(
  data: Record<string, any>,
  piiColumns: PiiColumn[]
): Record<string, any> {
  return applyMaskingToObject(data, piiColumns, {
    actorMaxLevel: 'L1',
    isExternal: true,
    forceMasked: true
  });
}

// 사용
logger.info('Delivery dispatched', safeLog({ delivery, driver }, DELIVERY_PII_COLUMNS));
```

## 5. ESLint 정적 분석 (선택)

PII 컬럼 직접 응답 / 로그 사용 시 경고:

```javascript
// eslint-rules/no-raw-pii.js

module.exports = {
  meta: {
    type: 'problem',
    docs: { description: 'Disallow raw PII fields in response/log without masking' }
  },
  create(context) {
    const PII_FIELD_NAMES = ['recipientName', 'recipientPhone', 'recipientAddress',
                             'employeeName', 'employeeSsn', 'driverLocation'];
    return {
      Property(node) {
        if (
          node.key.type === 'Identifier' &&
          PII_FIELD_NAMES.includes(node.key.name) &&
          isInResponseOrLog(node, context)
        ) {
          context.report({
            node,
            message: `'${node.key.name}' is a PII field — use applyMaskingToObject() or maskForExternal().`
          });
        }
      }
    };
  }
};
```

> ⚠️ ESLint 룰은 보조 도구. 핵심은 런타임 마스킹 미들웨어.

## 6. PII 컬럼 카탈로그 (모듈별)

```typescript
// business/_shared/pii/catalogs.ts

export const DELIVERY_PII_COLUMNS: PiiColumn[] = [
  { key: 'recipientName', rule: 'lastnameOnly', unmaskLevel: 'L3' },
  { key: 'recipientPhone', rule: 'middle4', unmaskLevel: 'L3' },
  { key: 'recipientAddress', rule: 'districtOnly', unmaskLevel: 'L3' },
  { key: 'recipientPostal', rule: 'last4', unmaskLevel: 'L3' }
];

export const POD_PII_COLUMNS: PiiColumn[] = [
  { key: 'delegateName', rule: 'lastnameOnly', unmaskLevel: 'L3' },
  { key: 'signatureUrl', rule: 'redact', unmaskLevel: 'L3' },
  { key: 'photoUrls', rule: 'redact', unmaskLevel: 'L3' },
  { key: 'idMeta', rule: 'redact', unmaskLevel: 'L4' }
];

export const PAYROLL_PII_COLUMNS: PiiColumn[] = [
  { key: 'employeeName', rule: 'lastnameOnly', unmaskLevel: 'L4' },
  { key: 'employeeSsn', rule: 'hash', unmaskLevel: 'Super' },
  { key: 'employeeAccount', rule: 'last4', unmaskLevel: 'L4' }
];

export const DRIVER_LOCATION_PII_COLUMNS: PiiColumn[] = [
  { key: 'lat', rule: 'redact', unmaskLevel: 'L4' },
  { key: 'lng', rule: 'redact', unmaskLevel: 'L4' }
];
```

`.claude/rules/permissions.md` § 4 의 매트릭스와 동기 유지 — 룰 변경 시 카탈로그도 갱신.

## 7. 테스트 시나리오

### 7.1 등급별 마스킹

```typescript
test('L2 actor → 이름 마스킹', () => {
  const result = applyMaskingToObject(
    { recipientName: '홍길동' },
    DELIVERY_PII_COLUMNS,
    { actorMaxLevel: 'L2', isExternal: false }
  );
  expect(result.recipientName).toBe('홍**');
});

test('L4 actor → 이름 풀', () => {
  const result = applyMaskingToObject(
    { recipientName: '홍길동' },
    DELIVERY_PII_COLUMNS,
    { actorMaxLevel: 'L4', isExternal: false }
  );
  expect(result.recipientName).toBe('홍길동');
});
```

### 7.2 외부 노출 강제 마스킹

```typescript
test('isExternal=true → L4 도 마스킹', () => {
  const result = applyMaskingToObject(
    { recipientName: '홍길동' },
    DELIVERY_PII_COLUMNS,
    { actorMaxLevel: 'L4', isExternal: true }
  );
  expect(result.recipientName).toBe('홍**');
});
```

### 7.3 마스킹 함수 단위

```typescript
test.each([
  ['홍길동', 'lastnameOnly', '홍**'],
  ['Bob Smith', 'lastnameOnly', 'B*********'],
  ['010-1234-5678', 'middle4', '010-****-5678'],
  ['1234567890', 'last4', '******7890'],
  ['서울특별시 강남구 삼성로 100', 'districtOnly', '서울특별시 강남구 ***'],
  ['SECRET', 'redact', '***']
])('mask(%s, %s) === %s', (input, rule, expected) => {
  expect(maskValue(input, rule as MaskRule)).toBe(expected);
});
```

### 7.4 응답 미들웨어 통합

```typescript
test('GET /deliveries/:id 자동 마스킹', async () => {
  const handler = withPiiProtection(DELIVERY_PII_COLUMNS, async (input, ctx) => ({
    id: 'd-1',
    recipientName: '홍길동',
    recipientPhone: '010-1234-5678'
  }));

  const result = await handler({ id: 'd-1' }, { actor: { maxLevel: 'L2' }});
  expect(result.recipientName).toBe('홍**');
  expect(result.recipientPhone).toBe('010-****-5678');
});
```

## 8. 통합 가이드

### 8.1 신규 라우트 작성 표준

```
1. 응답 객체에 PII 컬럼 식별
2. 해당 모듈의 PII_COLUMNS 카탈로그에 추가
3. 라우트에 withPiiProtection() 래퍼 적용
4. (옵션) ESLint 룰 활성화
```

### 8.2 외부 노출 경로 체크리스트

- [ ] API 응답 → `withPiiProtection`
- [ ] 이메일 본문 → `maskForExternal`
- [ ] webhook 페이로드 → `maskForExternal`
- [ ] Slack / Teams 알림 → `maskForExternal`
- [ ] 로그 / audit → `safeLog`
- [ ] 메트릭 라벨 → PII 절대 X (id 만)

### 8.3 룰 갱신

`.claude/rules/permissions.md` § 4 (PII 매트릭스) 끝에 추가:

```
## 4.7 코드 강제 (v0.3+)

`.claude/boilerplate/06_pii_masking_enforcement.md` 의 `withPiiProtection` / `maskForExternal` /
`safeLog` 헬퍼 사용. 직접 PII 컬럼 응답 / 로그 / 외부 노출 금지.

PII 컬럼 카탈로그: `business/_shared/pii/catalogs.ts` — 본 § 4 매트릭스와 동기 유지.
```

## 9. 검증 체크리스트

- [ ] 마스킹 함수 단위 테스트
- [ ] applyMaskingToObject 등급별 테스트
- [ ] 외부 노출 강제 마스킹 테스트
- [ ] withPiiProtection 미들웨어 통합 테스트
- [ ] PII 카탈로그 (4 모듈) 정의
- [ ] ESLint 룰 (보조)
- [ ] `.claude/rules/permissions.md` § 4.7 갱신

## 10. 참조

- 룰: `.claude/rules/permissions.md` § 4 (PII 매트릭스)
- 모듈별 PII 컬럼:
  - logistics: `delivery.md` § EL-070, `tracking_pod.md` § EL-350
  - payroll: `payment.md` § EP-560 (계좌), `payslip.md` (이름)
  - reports: `report_definition.md` § ER-090 (PII 매트릭스)
- 의존: 없음 (독립)
