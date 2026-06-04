# Boilerplate Code Specs — 인덱스

> **상위**: `../CLAUDE.md` (또는 루트 README)
> **버전**: v0.3 (Phase 0.5 — boilerplate 갭 작업)
> **목적**: `@erp-harness/core` v0.9.0 에 대한 8개 boilerplate 갭 명세 + 구현 가이드

---

## 0. 적용 정책

이 디렉터리는 **코드 명세** — 룰 (`.claude/rules/`, `.claude/products/`) 과 별개:

- 룰 = "무엇이 / 왜" 강제되어야 하는가 (도메인 / 정책)
- 코드 명세 = "어떻게" 그것을 구현하는가 (인터페이스 / 패턴 / 테스트)

각 갭 명세는 다음 5 섹션 표준:
1. 갭 정의 (현재 상태 / 영향 / 목표)
2. 인터페이스
3. 핵심 구현
4. 사용 예시 / 테스트 시나리오
5. 통합 가이드 + 검증 체크리스트

---

## 1. 갭 카탈로그 (8개)

| # | 파일 | 주제 | 의존 | 우선순위 |
|---|---|---|---|---|
| 01 | `01_processed_event_helper.md` | ProcessedEvent 멱등 헬퍼 | 없음 | **P0** (모든 핸들러 기반) |
| 02 | `02_outbox_publisher.md` | Outbox publisher worker | 갭 01 | **P0** (이벤트 흐름) |
| 03 | `03_saga_retry_backoff.md` | Saga retry / backoff 정책 | 갭 01, 02 | P1 |
| 04 | `04_saga_resume.md` | Saga 자동 resume | 갭 03 | P1 |
| 05 | `05_memory_event_bus_flush.md` | InMemoryEventBus flush 한계 | 없음 (독립) | P1 (테스트) |
| 06 | `06_pii_masking_enforcement.md` | PII 마스킹 코드 자동 강제 | 없음 (독립) | P1 (보안) |
| 07 | `07_operations_cli.md` | 운영 CLI / Admin | 갭 02, 04, 06 | P2 |
| 08 | `08_readme_code_sync.md` | README ↔ 코드 정합 | 갭 01~07 | P2 (마지막) |

---

## 2. 의존성 그래프

```
        ┌────────────┐
        │ 01 멱등 헬퍼│
        └─────┬──────┘
              │
         ┌────┴────┐
         ▼         ▼
   ┌─────────┐ ┌──────────┐
   │ 02 outbox│ │   기타    │
   │ publisher│ │  핸들러   │
   └────┬────┘ └──────────┘
        │
        ▼
   ┌─────────┐
   │ 03 saga │
   │ retry   │
   └────┬────┘
        │
        ▼
   ┌─────────┐    ┌──────────┐    ┌──────────┐
   │ 04 saga │    │ 05 bus   │    │ 06 PII   │
   │ resume  │    │ flush    │    │ enforce  │
   └────┬────┘    └────┬─────┘    └────┬─────┘
        │              │               │
        └──────────────┴───────┬───────┘
                               ▼
                       ┌──────────────┐
                       │ 07 CLI       │
                       └──────┬───────┘
                              │
                              ▼
                       ┌──────────────┐
                       │ 08 README    │
                       │   sync       │
                       └──────────────┘
```

---

## 3. 키워드 → 갭 트리거

| 키워드 | 갭 |
|---|---|
| 멱등 / processedEvent / withIdempotency / 자연 키 | 01 |
| outbox / publisher / DLQ / 발행 / SKIP LOCKED | 02 |
| saga step / 재시도 / backoff / 보상 | 03 |
| saga resume / 서버 재시작 / stale | 04 |
| InMemoryEventBus / flush / drain / 테스트 / 핸들러 체인 | 05 |
| PII / 마스킹 / 외부 노출 / withPiiProtection | 06 |
| CLI / admin / DLQ 재처리 / 운영 명령 | 07 |
| README / 문서 정합 / 버전 표기 / cross-link | 08 |

---

## 4. 영향 받는 룰 (cross-link)

각 갭 작업 후 룰 갱신 필요:

| 갭 | 영향 룰 |
|---|---|
| 01 | `rules/integration.md` § 1.3 (멱등) |
| 02 | `rules/integration.md` § 1.1 (outbox) |
| 03 | `rules/integration.md` § 1.5 (saga) |
| 04 | `rules/integration.md` § 1.5 (saga + resume) |
| 05 | `rules/integration.md` § 4 (테스트 / 관측) |
| 06 | `rules/permissions.md` § 4.7 (PII 코드 강제 신규) |
| 07 | `rules/permissions.md` § 6.4 (CLI 액세스 신규) |
| 08 | 모든 룰 (정합 검증 대상) |

---

## 5. Phase 0 → Phase 1 진입 조건

이 8개 갭 모두 완료 시 Phase 1 진입:

| 영역 | Phase 0 | Phase 0.5 (이 작업) | Phase 1 |
|---|---|---|---|
| 룰 / 스키마 | ✅ 완료 (v0.2) | — | — |
| 멱등 / outbox 인프라 | ⚠️ 일부 | ✅ (갭 01, 02) | — |
| Saga 안정성 | ⚠️ 일부 | ✅ (갭 03, 04) | — |
| 테스트 인프라 | ⚠️ flaky | ✅ (갭 05) | — |
| PII 보안 | ⚠️ 룰만 | ✅ (갭 06) | — |
| 운영 도구 | ❌ 없음 | ✅ (갭 07) | — |
| 문서 정합 | ⚠️ 분산 | ✅ (갭 08) | — |
| **Phase 1: 핸들러 코드** | — | — | 진입 가능 |

---

## 6. 작업 우선순위 (권장)

### 6.1 P0 (먼저 — 모든 핸들러의 기반)

1. **갭 01 — ProcessedEvent 헬퍼**
   - 가장 영향 큼 (모든 핸들러)
   - 작업량: 1~2일

2. **갭 02 — Outbox publisher**
   - cross-module 이벤트 흐름의 핵심
   - 작업량: 2~3일

### 6.2 P1 (병렬 가능)

3. **갭 03 + 04 — Saga retry / resume**
   - 함께 진행 (의존 관계)
   - 작업량: 3~5일

4. **갭 05 — Bus flush** (테스트 인프라)
   - 독립, 빠름
   - 작업량: 1일

5. **갭 06 — PII enforcement** (보안)
   - 독립, 신중하게
   - 작업량: 2~3일

### 6.3 P2 (마지막)

6. **갭 07 — CLI**
   - 갭 02, 04, 06 의존
   - 작업량: 3~5일

7. **갭 08 — README sync**
   - 모든 작업 후 마무리
   - 작업량: 1일

**총 예상**: 13~21일 (1인 기준, 병렬 / 우선순위 따라 단축 가능).

---

## 7. 검증 매트릭스 (전체)

| 갭 | 단위 테스트 | 통합 테스트 | 운영 검증 |
|---|---|---|---|
| 01 | ✅ withIdempotency / withDualIdempotency | race condition (3+ 동시) | 중복 처리 지표 |
| 02 | ✅ tick / publishOne / DLQ | InMemoryEventBus 통합 | DLQ 알림 / pending gauge |
| 03 | ✅ retry / compensate | end-to-end saga | 보상 실패 알림 |
| 04 | ✅ resumeAllOnStartup / tick | SKIP LOCKED 분산 | stale saga 알림 |
| 05 | ✅ flush / drain / chain | 모든 통합 테스트 마이그레이션 | 테스트 안정성 |
| 06 | ✅ 마스킹 함수 / 미들웨어 | 응답 / 로그 / 외부 | PII 누설 모니터 |
| 07 | ✅ 명령별 service 단위 | dry-run / audit | 운영 절차 검증 |
| 08 | ✅ sync check 함수 | CI 통합 | docs:check PR 차단 |

---

## 8. 산출물 (Phase 0.5 종료 시)

| 종류 | 위치 |
|---|---|
| 갭 명세 8개 | `.claude/boilerplate/0X_*.md` (이 디렉터리) |
| 인덱스 | `.claude/boilerplate/INDEX.md` |
| 코드 (구현) | `@erp-harness/core` 본 패키지 (별도 트랙) |
| 룰 갱신 | `rules/integration.md` § 1, `rules/permissions.md` § 4.7 / § 6.4 |
| 운영 도구 | `tools/erp-cli/` |
| 테스트 | `__tests__/idempotency.test.ts` 등 |

---

## 9. 참조

- 4-모듈 통합: `../products/CLAUDE.md`
- 공통 룰: `../rules/INDEX.md`
- v0.2 cross-module: `../migrations/v0.2-cross-module/INDEX.md`
- ERP Harness boilerplate (별도 패키지): `@erp-harness/core` v0.9.0
