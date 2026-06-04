# Common Rules — 인덱스

> **상위**: `../CLAUDE.md`
> **버전**: v0.1 (4-모듈 통합 공통 룰)
> **참조**: 각 모듈 `products/{module}/rules/INDEX.md`

---

## 0. 적용 범위

이 디렉터리는 **payroll / inventory / logistics / reports** 4 모듈을 가로지르는 공통 룰을 정의한다.

- 각 모듈 룰은 이 공통 룰을 준수
- 모듈 간 상호작용은 이 문서들에서 결정
- Phase 1+ 코드 구현의 기반

---

## 1. 문서 카탈로그

| 파일 | 주제 | 키워드 |
|---|---|---|
| `permissions.md` | 권한 등급 / 매트릭스 / PII / 마감 | L1~Super, 권한 분리, PII 마스킹, audit |
| `integration.md` | 이벤트 / outbox / saga / 외부 시스템 | PUB/SUB, 멱등, webhook, 시퀀스 |
| `database.md` | DDL 규약 / 인덱스 / 마이그레이션 | NUMERIC, UUID, ENUM, FK, RLS |

---

## 2. 키워드 → 파일 트리거

| 키워드 | 파일 |
|---|---|
| 권한 / L1~Super / 등급 / 부여 / 회수 | `permissions.md` |
| 권한 분리 / 입력자 ≠ 승인자 | `permissions.md` § 2.1 |
| PII / 마스킹 / 풀 PII | `permissions.md` § 4 |
| 마감 / immutable / period_closed | `permissions.md` § 5 |
| audit log / 감사 / 보존 | `permissions.md` § 7 |
| 이벤트 / PUB / SUB / outbox / 멱등 | `integration.md` |
| saga / 보상 트랜잭션 / 분산 | `integration.md` § 1.5 |
| 시퀀스 다이어그램 / 흐름 | `integration.md` § 4 |
| 페이로드 / 메시지 형식 | `integration.md` § 5 |
| webhook / 외부 carrier / ESP | `integration.md` § 7 |
| 데이터 타입 / NUMERIC / UUID | `database.md` § 3 |
| 명명 규약 / snake_case | `database.md` § 2 |
| 인덱스 / 부분 / 복합 / GIN | `database.md` § 6 |
| 마이그레이션 / Prisma / ENUM 추가 | `database.md` § 7 |
| 백업 / 복구 / PITR | `database.md` § 8 |
| 보안 / 시크릿 / 암호화 / RLS | `database.md` § 9 |

---

## 3. 적용 우선순위

분쟁 / 모호함 발생 시:

1. **공통 룰 (이 디렉터리)** — 모든 모듈에 적용되는 규약
2. **모듈 룰** — 모듈 특수 영역
3. **개별 결정** — 명시 사례

예:
- 권한 등급 정의 → `permissions.md` § 1 우선
- 모듈 특수 권한 (payroll payment 승인 분리) → 모듈 룰
- 둘 다 명시 안 됨 → 운영자 / 아키텍트 결정 + 룰 보강

---

## 4. Cross-link 매트릭스

각 모듈 룰의 § 권한 / 감사 → `permissions.md` 참조  
각 모듈 룰의 § 4 (외부 약속) → `integration.md` 참조  
각 모듈 schema INDEX → `database.md` 참조

---

## 5. Phase 1+ 추가 예정

- `agents.md` — 에이전트 (Claude / 자동화 봇) 권한 정책
- `i18n.md` — 다국어 / 다통화 (Phase 2+)
- `disaster_recovery.md` — DR / 장애 대응 절차 (Phase 1+)
- `compliance.md` — KR 인증 / GDPR / SOC2 (Phase 2+)

---

## 6. 참조

- 4-모듈 통합 정체성: `../products/CLAUDE.md`
- 각 모듈 CLAUDE.md:
  - `../products/payroll/CLAUDE.md`
  - `../products/inventory/CLAUDE.md`
  - `../products/logistics/CLAUDE.md`
  - `../products/reports/CLAUDE.md`
