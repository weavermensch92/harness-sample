# 갭 07 — 운영 CLI / Admin 진입점

> **버전**: v0.3 진입 시 구현
> **위치**: `@erp-harness/core/cli` 또는 `tools/erp-cli/`
> **영향**: 운영 / DevOps / 비상 대응
> **의존**: 갭 02 (outbox), 갭 04 (saga resume), 갭 06 (PII)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- 비즈니스 코드는 핸들러 / API 진입점만 — 운영 진입점 없음
- DLQ 재처리 / saga 수동 재개 / feature flag 변경 / 마감 처리 등은 **DB 직접 조작** 필요
- 운영자가 SQL 작성하다 사고 위험 (예: WHERE 절 누락 → 전체 update)

### 영향

- 비상 시 DB 직접 작업 → 사고 위험 (운영자가 사용자가 됨)
- 정형화된 운영 절차 없음
- audit 자동 기록 안 됨 (수동 SQL 은 audit_logs 에 안 남음)

### 목표

명령어 단위 운영 진입점 — 모든 명령은 audit + 권한 검증 + dry-run 지원.

---

## 1. CLI 구조

```bash
erp-cli <namespace> <command> [args] [--options]

# 네임스페이스
erp-cli outbox     # 이벤트 발행 / DLQ
erp-cli saga       # 분산 트랜잭션 관리
erp-cli flag       # feature flag 조회 / 변경
erp-cli period     # 마감 / 재오픈
erp-cli pii        # PII 데이터 주체 요청
erp-cli health     # 시스템 진단
erp-cli backfill   # 데이터 백필 (예: inventory weight)
```

## 2. 핵심 명령 카탈로그

### 2.1 outbox

```bash
# DLQ 목록
erp-cli outbox dlq list [--event-type X] [--since 1h] [--limit 50]

# DLQ 재처리 (단일 / 일괄)
erp-cli outbox dlq retry <event-id>
erp-cli outbox dlq retry --all --event-type logistics.delivery.dispatched

# DLQ 영구 삭제 (위험)
erp-cli outbox dlq purge <event-id> --reason "..." --confirm
erp-cli outbox dlq purge --before 30d --confirm

# 통계
erp-cli outbox stats [--since 1h]
# 출력: pending: 5, publishing: 0, published: 1234, failed: 12, dlq: 2

# 발행 강제 (운영 비상)
erp-cli outbox force-publish <event-id>
```

### 2.2 saga

```bash
# 진행 중 saga 목록
erp-cli saga list [--status RUNNING|COMPENSATING] [--type X]

# saga 상세 (state + step ledger)
erp-cli saga show <saga-id>

# 수동 재개 (resumer 가 누락한 경우)
erp-cli saga resume <saga-id>

# 강제 보상 트랜잭션 실행
erp-cli saga compensate <saga-id> --reason "..." --confirm

# stale (1h+ RUNNING) saga 발견
erp-cli saga stale [--older 1h]
```

### 2.3 flag

```bash
# 토글 조회
erp-cli flag list --org <org-id>
erp-cli flag get inventory.lot_tracking --org <org-id>

# 토글 변경
erp-cli flag set inventory.fefo_dispatch true --org <org-id> --reason "약사법 강화"

# 시드 (KR 법정 묶음)
erp-cli flag seed report.kr_legal_pack --org <org-id>
```

### 2.4 period (마감)

```bash
# 마감 요청
erp-cli period close payroll 2026-04 --org <org-id> --by <user-id>

# 마감 후 재오픈 (Super 강제)
erp-cli period reopen payroll 2026-04 --reason "..." --confirm

# 진행 중 마감 상태
erp-cli period status --org <org-id>
```

### 2.5 pii (개인정보보호법 §35)

```bash
# 데이터 주체 요청 (삭제 / 마스킹)
erp-cli pii request submit --user-id X --type erasure --reason "..."

# 처리 상태
erp-cli pii request list [--status PENDING|PROCESSING|COMPLETED]

# 처리 (운영자)
erp-cli pii request process <request-id> --action mask --confirm
erp-cli pii request process <request-id> --action delete --confirm
```

### 2.6 health (진단)

```bash
# 시스템 전체 health
erp-cli health check
# 출력:
#   ✅ Database: connected (latency 12ms)
#   ✅ Outbox publisher: running (pending 3)
#   ✅ Saga resumer: running (RUNNING 5, COMPENSATING 1)
#   ⚠️  Outbox DLQ: 2 events
#   ✅ External: CJ carrier API (ok), SES (ok)
#   ❌ Schema drift: 1 missing FK (logistics_routes.warehouse_id)

# 특정 영역
erp-cli health outbox
erp-cli health saga
erp-cli health schema   # FK / 인덱스 정합 (마이그레이션 004)
```

### 2.7 backfill

```bash
# 운영 데이터 일괄 보정
erp-cli backfill inventory-weight --csv path/to/data.csv --dry-run
erp-cli backfill driver-license-expiry --org <org-id> --confirm
```

## 3. 핵심 구현

### 3.1 명령 프레임워크

```typescript
// tools/erp-cli/src/cli.ts

import { Command } from 'commander';
import { setupOutboxCommands } from './commands/outbox';
import { setupSagaCommands } from './commands/saga';

const program = new Command()
  .name('erp-cli')
  .description('ERP Harness operations CLI')
  .version('0.3.0');

setupOutboxCommands(program);
setupSagaCommands(program);
// ...

program.parse();
```

### 3.2 명령 표준 (모든 명령 공통)

```typescript
// tools/erp-cli/src/commands/outbox.ts

import { authenticate, requirePermission, writeAudit } from '@erp-shared';

export function setupOutboxCommands(program: Command) {
  const cmd = program.command('outbox').description('Outbox event management');

  cmd.command('dlq:retry <eventId>')
    .description('Retry a DLQ event')
    .option('--reason <reason>', 'Reason (required)')
    .option('--confirm', 'Confirm the action')
    .action(async (eventId, options) => {
      await runWithStandard({
        commandName: 'outbox.dlq.retry',
        args: { eventId, ...options },
        requiredLevel: 'Super',
        requireConfirm: true,
        action: async (actor) => {
          const event = await db.eventOutbox.findUnique({ where: { eventId }});
          if (!event || event.status !== 'DLQ') {
            throw new Error(`Event ${eventId} is not in DLQ`);
          }
          await db.eventOutbox.update({
            where: { eventId },
            data: { status: 'PENDING', attemptCount: 0, nextAttemptAt: null }
          });
          return `Event ${eventId} reset to PENDING`;
        }
      });
    });
}

/** 모든 명령 공통 표준 — auth / 권한 / dry-run / audit */
async function runWithStandard<T>(opts: {
  commandName: string;
  args: Record<string, unknown>;
  requiredLevel: 'L4' | 'Super';
  requireConfirm?: boolean;
  dryRun?: boolean;
  action: (actor: User) => Promise<T>;
}): Promise<T> {
  // 1. 인증 (CLI 토큰 / SSH key / kerberos 등)
  const actor = await authenticate();

  // 2. 권한
  await requirePermission(actor, 'admin', opts.requiredLevel);

  // 3. 확인 (위험한 작업)
  if (opts.requireConfirm && !opts.args.confirm) {
    console.error('--confirm required');
    process.exit(1);
  }

  // 4. dry-run
  if (opts.dryRun || opts.args.dryRun) {
    console.log('DRY RUN — no changes applied');
    return null as any;
  }

  // 5. 실행 + audit
  const startedAt = new Date();
  try {
    const result = await opts.action(actor);
    await writeAudit({
      action: `cli.${opts.commandName}`,
      actor: actor.id,
      metadata: { args: redactSecrets(opts.args), result, durationMs: Date.now() - startedAt.getTime() }
    });
    console.log(result);
    return result;
  } catch (e) {
    await writeAudit({
      action: `cli.${opts.commandName}.failed`,
      actor: actor.id,
      metadata: { args: redactSecrets(opts.args), error: (e as Error).message }
    });
    throw e;
  }
}
```

### 3.3 인증 (CLI)

```typescript
// tools/erp-cli/src/auth.ts

export async function authenticate(): Promise<User> {
  // 옵션 1: 환경변수 토큰 (CI / 자동화)
  const token = process.env.ERP_CLI_TOKEN;
  if (token) {
    return await validateToken(token);
  }

  // 옵션 2: SSH key (운영자 노트북)
  const sshAuth = await trySshAuth();
  if (sshAuth) return sshAuth;

  // 옵션 3: 대화형 (개발 환경만)
  if (process.env.NODE_ENV === 'development') {
    return await interactiveLogin();
  }

  throw new Error('No authentication method available');
}
```

## 4. 운영 시나리오

### 4.1 DLQ 알림 → 재처리

```bash
# 알림 수신: "Outbox event DLQ: logistics.delivery.dispatched (evt-xxx)"

# 1. 상태 확인
$ erp-cli outbox dlq list --event-type logistics.delivery.dispatched
EVENT_ID                              EVENT_TYPE                       LAST_ERROR              ATTEMPTS
evt-xxx                               logistics.delivery.dispatched    NetworkError: timeout   24

# 2. 외부 의존 복구 확인 (수동)

# 3. 재처리
$ erp-cli outbox dlq retry evt-xxx --reason "External API recovered" --confirm
✅ Event evt-xxx reset to PENDING

# 4. publisher 가 자동으로 발행 시도
$ erp-cli outbox stats
pending: 1, publishing: 0, published: 1234, failed: 0, dlq: 1
```

### 4.2 stale saga 발견 → 수동 처리

```bash
# 1. stale saga 목록
$ erp-cli saga stale --older 24h
SAGA_ID                              TYPE             STATUS    CURRENT_STEP    LAST_UPDATED
saga:order:abc                       order_confirmed  RUNNING   create_invoice  2 days ago

# 2. 상세 진단
$ erp-cli saga show saga:order:abc
type: order_confirmed
status: RUNNING (currentStep=create_invoice)
attemptCount: 24
lastError: ExternalInvoiceServiceError
context: { orderId: 'abc', deliveryId: 'd-1' }
...

# 3. 결정 — 보상 트랜잭션
$ erp-cli saga compensate saga:order:abc --reason "External invoice service down indefinitely" --confirm
✅ Compensating saga:order:abc...
- Step 'create_reservation' compensated
- Step 'create_delivery_draft' compensated
✅ Saga COMPENSATED
```

### 4.3 운영 데이터 백필 (inventory weight)

```bash
# 1. CSV 준비
sku,weight,weight_uom
SKU-001,2.5,kg
SKU-002,500,g
...

# 2. dry-run
$ erp-cli backfill inventory-weight --csv data.csv --dry-run
Would update 1234 items
- SKU-001: weight=2.5kg (current: NULL)
- SKU-002: weight=500g (current: NULL)
...

# 3. 실 적용
$ erp-cli backfill inventory-weight --csv data.csv --confirm
✅ 1234 items updated
audit: cli.backfill.inventory-weight (actor=user-xxx)
```

## 5. 권한 매트릭스 (CLI 명령별)

| 명령 | 최소 권한 |
|---|---|
| `outbox dlq list` | L4 |
| `outbox dlq retry` | Super |
| `outbox dlq purge` | Super + 강화 audit |
| `saga list / show` | L4 |
| `saga resume` | Super |
| `saga compensate` | Super + 강화 audit |
| `flag set` | L4 (조직) / Super (시스템) |
| `period close` | L4 |
| `period reopen` | Super + 강화 audit |
| `pii request *` | L4 (요청) / Super (처리) |
| `health *` | L3 |
| `backfill *` | Super |

## 6. 테스트

CLI 자체는 thin wrapper — 실 로직은 service 함수로 분리해서 테스트:

```typescript
// __tests__/cli/outbox.test.ts
test('dlq retry → PENDING 으로 리셋', async () => {
  await db.eventOutbox.create({
    data: { eventId: 'evt-test', status: 'DLQ', attemptCount: 24, /* ... */ }
  });

  await retryDlqEvent({ eventId: 'evt-test', actor: superUser, reason: 'test' });

  const updated = await db.eventOutbox.findUnique({ where: { eventId: 'evt-test' }});
  expect(updated?.status).toBe('PENDING');
  expect(updated?.attemptCount).toBe(0);

  // audit 확인
  const audit = await db.auditLog.findFirst({ where: { action: 'cli.outbox.dlq.retry' }});
  expect(audit).toBeDefined();
});
```

## 7. 통합 가이드

### 7.1 배포 / 사용

```bash
# 패키지 설치
npm install -g @erp/cli

# 또는 Docker
docker run --rm \
  -e ERP_CLI_TOKEN=$TOKEN \
  -e DATABASE_URL=$DATABASE_URL \
  erp-cli outbox stats
```

### 7.2 권장: read-only 모드 우선

신입 운영자 / 임시 권한 → read-only:
```bash
erp-cli --read-only saga list
# write 명령 (retry / compensate 등) 거부
```

### 7.3 룰 갱신

`.claude/rules/permissions.md` § 6 (권한 부여) 보강:

```
## 6.4 CLI 액세스 (v0.3+)

운영 CLI 사용은 별도 권한 — `.claude/boilerplate/07_operations_cli.md` 참조.
모든 CLI 명령은 자동 audit (`cli.{command}` action).
Super 강제 액션은 강화 audit + Slack 알림 + 월간 리뷰.
```

## 8. 검증 체크리스트

- [ ] 명령 프레임워크 (Commander) 통합
- [ ] auth (토큰 / SSH / 대화형)
- [ ] 표준 wrapper (auth + 권한 + dry-run + audit)
- [ ] 핵심 명령 7 네임스페이스
- [ ] 운영 시나리오 통합 테스트
- [ ] read-only 모드
- [ ] CLI 패키징 (npm / Docker)
- [ ] `rules/permissions.md` § 6.4 갱신

## 9. 참조

- 의존: 갭 02 (outbox dlq), 갭 04 (saga), 갭 06 (PII)
- 룰: `.claude/rules/permissions.md` § 6 (권한 부여)
