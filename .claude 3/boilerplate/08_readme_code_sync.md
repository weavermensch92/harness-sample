# 갭 08 — README ↔ 코드 정합

> **버전**: v0.3 진입 시 정리 (가벼운 작업)
> **위치**: `@erp-harness/core` 의 README 들 + `.claude/products/CLAUDE.md` 와 동기
> **영향**: 신규 개발자 온보딩 / 외부 개발자 / 문서 신뢰도
> **의존**: 갭 01~07 작업 완료 후 (실제 상태 확정 후 갱신)

---

## 0. 갭 정의

### 현재 상태 (v0.9.0)

- README 가 "Phase 0" 표기 — 실제 코드는 v0.9.0 (스키마 / Saga / EventBus 일부 구현)
- README ↔ `.claude/products/*/CLAUDE.md` ↔ 실 코드 사이 표기 불일치
- 신규 개발자가 어디서부터 보아야 할지 혼란

### 영향

- 온보딩 시간 증가
- 외부 개발자 (오픈소스 / 파트너) 신뢰도 저하
- 문서 의존 자동화 도구 (예: skills) 가 잘못된 정보 사용

### 목표

문서 / 룰 / 코드 사이의 정합 매트릭스 + 자동 검증 cron + 단일 진입점.

---

## 1. 문서 계층 정리

### 1.1 단일 진입점 — 루트 README

```
@erp-harness/core/
├── README.md                           ← 단일 진입점
├── packages/
│   ├── core/
│   │   ├── README.md                   ← 코어 라이브러리 사용법
│   │   └── ...
│   ├── cli/
│   │   ├── README.md                   ← 갭 07 CLI
│   │   └── ...
│   └── ...
├── .claude/                            ← 룰 / 스키마 / boilerplate (이 작업)
│   ├── products/CLAUDE.md
│   ├── rules/INDEX.md
│   └── boilerplate/
└── docs/
    ├── architecture.md
    ├── getting-started.md
    └── ...
```

### 1.2 README 책임 분담 (MUST)

| 파일 | 책임 |
|---|---|
| 루트 `README.md` | 한 페이지 — 무엇 / 누구를 위해 / 어디로 가는가 |
| `packages/*/README.md` | 패키지 사용법 + API |
| `docs/architecture.md` | 시스템 아키텍처 (cross-link 종합) |
| `docs/getting-started.md` | 개발자 온보딩 5분 |
| `.claude/products/CLAUDE.md` | 4-모듈 통합 정체성 + 룰 |
| `.claude/rules/INDEX.md` | 공통 룰 카탈로그 |
| 각 모듈 `CLAUDE.md` | 모듈 정체성 + Phase 상태 |

루트 README ↔ `products/CLAUDE.md` 는 **다른 독자** — README 는 외부 / 신입, CLAUDE.md 는 Claude / 자동화.

---

## 2. 루트 README.md 표준 구조

```markdown
# ERP Harness

> KR 시장 ERP 4-모듈 (payroll / inventory / logistics / reports) 의 도메인 룰 + 코드 보일러플레이트.
>
> Status: Phase 0 / v0.3 (룰 / 스키마 완료, 핸들러 구현 진행 중)

## 무엇인가
- 도메인 룰 (rules) 과 데이터 모델 (schemas) 을 모듈별로 정의
- 멱등 / 이벤트 / saga 등의 boilerplate 패턴 제공
- KR 노동법 / 세법 / 식품위생법 / 약사법 / 전자상거래법 / K-IFRS 도메인 룰 내장

## 누구를 위해
- ERP 도메인 개발자
- Claude 같은 AI 에이전트가 따라야 할 룰

## 빠른 시작
- 신입 개발자: [docs/getting-started.md](./docs/getting-started.md)
- 시스템 이해: [docs/architecture.md](./docs/architecture.md)
- 4-모듈 정체성: [.claude/products/CLAUDE.md](./.claude/products/CLAUDE.md)

## 모듈 상태

| 모듈 | 버전 | 룰 | 스키마 | 핸들러 |
|---|---|---|---|---|
| payroll  | v0.11+ | ✅ | ✅ | ⏸ Phase 1 |
| inventory | v0.2  | ✅ | ✅ | ⏸ Phase 1 |
| logistics | v0.2  | ✅ | ✅ | ⏸ Phase 1 |
| reports  | v0.1  | ✅ | ✅ | ⏸ Phase 1 |

상세: [.claude/products/{module}/CLAUDE.md](./.claude/products/)

## 인접 시스템
- Gridge AI MSP — 별도 시스템 (이 ERP 와 데이터 / 권한 / 인프라 분리)
- 자세한 차이: [docs/comparison.md](./docs/comparison.md)

## 라이선스 / 문의
- 라이선스: ...
- 이슈: GitHub Issues
- 문의: ...
```

루트 README 는 **한 페이지** — 더 깊은 정보는 cross-link.

---

## 3. 정합 매트릭스 (자동 검증)

### 3.1 검증 대상 매트릭스

```typescript
// tools/doc-sync/src/checks.ts

export const SYNC_CHECKS: SyncCheck[] = [
  {
    name: 'root_readme_version',
    description: 'README "Status" 가 모든 모듈의 max 버전과 일치',
    check: async () => {
      const readmeStatus = await extractStatusFromReadme('./README.md');
      const moduleVersions = await extractModuleVersions('./.claude/products/');
      const expected = `Phase 0 / v${maxVersion(moduleVersions)}`;
      return { ok: readmeStatus === expected, expected, actual: readmeStatus };
    }
  },
  {
    name: 'module_readme_phase_consistency',
    description: '각 모듈 CLAUDE.md 의 Phase 상태 ↔ products/CLAUDE.md 의 표 일치',
    check: async () => {
      const productsTable = await extractModuleTable('./.claude/products/CLAUDE.md');
      const moduleClaudes = await Promise.all(
        ['payroll', 'inventory', 'logistics', 'reports'].map(m =>
          extractPhaseStatus(`./.claude/products/${m}/CLAUDE.md`)
        )
      );
      // 모든 모듈 비교
      return compareTableAndDetails(productsTable, moduleClaudes);
    }
  },
  {
    name: 'enum_catalog_sync',
    description: '각 모듈의 ENUM 카탈로그 (rules INDEX) ↔ schemas SQL 일치',
    check: async () => {
      const rulesEnums = await extractEnumsFromRulesIndex('./.claude/products/inventory/rules/INDEX.md');
      const sqlEnums = await extractEnumsFromSql('./.claude/products/inventory/schemas/tables/');
      return diffEnums(rulesEnums, sqlEnums);
    }
  },
  {
    name: 'rule_id_uniqueness',
    description: '룰 ID 중복 없음 (모듈 내 + cross 모듈)',
    check: async () => await checkRuleIdUniqueness()
  },
  {
    name: 'cross_link_validity',
    description: '문서 간 링크가 실제 파일 가리킴',
    check: async () => await checkCrossLinks()
  },
  {
    name: 'feature_flag_catalog_sync',
    description: '룰의 토글 카탈로그 ↔ 스키마 코멘트 일치',
    check: async () => await checkFeatureFlagSync()
  }
];
```

### 3.2 CLI 통합

```bash
# 정합 검증
$ erp-cli health docs

✅ root_readme_version: Phase 0 / v0.3
✅ module_readme_phase_consistency: 4/4 modules in sync
❌ enum_catalog_sync: inventory.movement_source mismatch
   - rules INDEX has 9 values
   - SQL has 9 values
   - DIFF: rules contains 'RETURN' but SQL doesn't  ← 사용자가 발견 가능
✅ rule_id_uniqueness: 1234 unique IDs
⚠️  cross_link_validity: 2 broken links
   - .claude/rules/permissions.md → ./agents.md (file does not exist)
   - .claude/products/payroll/CLAUDE.md → ./scripts/dev.md (does not exist)
✅ feature_flag_catalog_sync: ok

3 issues found.
```

### 3.3 CI 통합

```yaml
# .github/workflows/docs-sync.yml
name: Docs Sync Check

on: [pull_request]

jobs:
  sync-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm install
      - run: npm run docs:check
        # 실패 시 PR 차단
```

---

## 4. 정합 자동 동기 (선택 — Phase 2+)

일부는 자동 생성 가능:

```typescript
// tools/doc-sync/src/generate.ts

// products/CLAUDE.md 의 모듈 표 자동 생성
async function generateModuleTable() {
  const modules = ['payroll', 'inventory', 'logistics', 'reports'];
  const rows = await Promise.all(modules.map(async (m) => {
    const claude = await readClaudeMd(`./.claude/products/${m}/CLAUDE.md`);
    return {
      name: m,
      prefix: extractPrefix(claude),     // EP- / EI- / EL- / ER-
      version: extractVersion(claude),
      role: extractRole(claude)
    };
  }));
  return formatMarkdownTable(rows);
}
```

이를 기반으로:
```bash
$ erp-cli docs generate products-table > /tmp/table.md
# diff with current — auto-PR 가능
```

---

## 5. 작업 순서

### 5.1 즉시 (수동 동기)

- [ ] 루트 README.md 작성 (위 § 2 표준)
- [ ] `.claude/products/CLAUDE.md` 의 v0.2 표기와 README 동기
- [ ] 각 모듈 CLAUDE.md 의 Phase 상태 ↔ products/CLAUDE.md 표 정합
- [ ] inventory rules INDEX § 4.5 ENUM ↔ schemas/tables 정합 (이미 완료, 검증)
- [ ] cross-link 검증 (모든 `[...]` 링크가 실제 파일 가리키는지)

### 5.2 Phase 1 (자동 검증)

- [ ] tools/doc-sync 패키지 작성
- [ ] CI 통합 (`docs:check` script)
- [ ] `erp-cli health docs` 명령 추가 (갭 07 통합)
- [ ] PR template 에 "docs sync 검증 완료" 체크박스

### 5.3 Phase 2+ (자동 생성)

- [ ] 모듈 표 / 통계 자동 생성
- [ ] ENUM 카탈로그 자동 생성 (SQL → Markdown)
- [ ] 룰 ID 매트릭스 자동 생성

---

## 6. 검증 체크리스트

- [ ] 루트 README.md 한 페이지 작성
- [ ] 모든 README / CLAUDE.md 의 버전 표기 정합
- [ ] cross-link 검증 (자동 / 수동)
- [ ] ENUM 카탈로그 정합
- [ ] CI 통합 (`docs:check`)
- [ ] `erp-cli health docs` (갭 07)
- [ ] 정합 깨짐 시 PR 차단

---

## 7. 참조

- 의존: 갭 01~07 (실 상태 확정 후 동기 가능)
- 보강: 없음 (마지막 갭)
- 룰: 모든 룰 (정합 검증 대상)

---

## 8. 사이드 노트 — Phase 표기 규약 (제안)

전 모듈 / 문서 일관:

```
Phase 0 / v0.X     — 룰 + 스키마 + 마이그레이션
Phase 0.5 / v0.X   — boilerplate 갭 작업 (이 작업, 갭 01~08)
Phase 1 / v1.X     — 핸들러 / 비즈니스 로직 코드
Phase 2 / v2.X     — 화면 / UX (디자이너 + 프론트엔드)
Phase 3 / v3.X     — 운영 안정화 / 모니터링 / DR
```

이 표기를 README + 모든 CLAUDE.md 에 반영.
