# Reports Screens — 인덱스 (프레임)

> **상위**: `../CLAUDE.md`
> **상태**: Phase 0 — 화면 ID + 라우팅 + 권한 매핑까지만. 실제 화면 / 디자인은 Phase 2+.
> **참조**: `../../../skills/designer/`, `../rules/INDEX.md`

---

## 0. 적용 정책

`payroll/inventory/logistics screens/INDEX.md` 와 동일.

---

## 1. 화면 ID 네임스페이스

화면 ID = `ERS-xxx` (Reports Screens).

| 범위 | 주제 | 우선순위 |
|---|---|---|
| ERS-001~049 | 본인 / 팀 보고서 (실행 / 결과 조회) | P0 |
| ERS-100~149 | 보고서 카탈로그 / 정의 (관리) | P0 |
| ERS-150~199 | 보고서 실행 / 결과 (관리) | P0 |
| ERS-200~249 | 스케줄 관리 | P1 |
| ERS-300~349 | 배포 (이메일 / API / Slack) | P1 |
| ERS-400~449 | 보존 / 감사 | P2 |
| ERS-500~549 | KR 법정 보고서 묶음 | P0 |
| ERS-700~749 | 외부 발송 설정 (Super) | P2 |
| ERS-900~949 | Super (feature flag / 정의 마스터) | P2 |

---

## 2. 화면 목록

### 2.1 본인 / 팀 보고서

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-001 | 본인 실행 가능 보고서 목록 | `/me/reports` | ER-080 |
| ERS-002 | 보고서 실행 (파라미터 입력) | `/me/reports/[code]/run` | ER-060, ER-115 |
| ERS-003 | 본인 실행 이력 | `/me/reports/runs` | ER-110 |
| ERS-004 | 결과 다운로드 | `/me/reports/runs/[id]/download` | ER-320 |
| ERS-005 | 진행 상태 / 폴링 | `/me/reports/runs/[id]/status` | ER-140 |

### 2.2 보고서 카탈로그 / 정의

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-100 | 보고서 정의 목록 | `/admin/reports/definitions` | ER-010 |
| ERS-110 | 정의 상세 (BUILTIN 읽기 전용) | `/admin/reports/definitions/[id]` | ER-020 |
| ERS-120 | 커스텀 정의 신규 / 편집 (Phase 1+) | `/admin/reports/definitions/new` | ER-030, ER-035 |
| ERS-130 | 정의 버전 이력 | `/admin/reports/definitions/[id]/versions` | ER-015 |
| ERS-140 | 정의 활성 / 비활성 | `/admin/reports/definitions/[id]/toggle` | ER-015 |

### 2.3 보고서 실행 / 결과 (관리)

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-150 | 실행 대시보드 (전체) | `/admin/reports/runs` | ER-110 |
| ERS-160 | 실행 상세 / 로그 | `/admin/reports/runs/[id]` | ER-180 |
| ERS-170 | 결과 다운로드 (마스킹 / 풀 선택) | `/admin/reports/runs/[id]/download` | ER-170, ER-175 |
| ERS-180 | 실행 취소 | `/admin/reports/runs/[id]/cancel` | ER-145 |
| ERS-190 | 실패 재시도 | `/admin/reports/runs/[id]/retry` | ER-128 |
| ERS-195 | immutable 강제 재생성 (Super) | `/super/reports/runs/[id]/regenerate` | ER-185 |

### 2.4 스케줄 관리

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-200 | 스케줄 목록 | `/admin/reports/schedules` | ER-210 |
| ERS-210 | 스케줄 신규 / 편집 | `/admin/reports/schedules/new` | ER-215, ER-230 |
| ERS-220 | 일시 정지 / 재개 | `/admin/reports/schedules/[id]/pause` | ER-260 |
| ERS-230 | 즉시 실행 (수동 트리거) | `/admin/reports/schedules/[id]/trigger-now` | ER-220 |
| ERS-240 | 실행 이력 (스케줄 트리거) | `/admin/reports/schedules/[id]/runs` | ER-110 |

### 2.5 배포

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-300 | 배포 이력 (전체) | `/admin/reports/distributions` | ER-310 |
| ERS-310 | 이메일 발송 (수동) | `/admin/reports/runs/[id]/email` | ER-330 |
| ERS-320 | API webhook 발송 (수동) | `/admin/reports/runs/[id]/api-push` | ER-340 |
| ERS-330 | 재발송 | `/admin/reports/distributions/[id]/resend` | ER-380 |
| ERS-340 | 반송 / 실패 처리 | `/admin/reports/distributions/failed` | ER-338 |

### 2.6 보존 / 감사

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-400 | 보존 정책 매트릭스 | `/admin/reports/retention` | ER-410, ER-415 |
| ERS-410 | 자동 삭제 이력 | `/admin/reports/purge-history` | ER-440 |
| ERS-420 | audit log 조회 | `/admin/reports/audit` | ER-460 |
| ERS-430 | 데이터 주체 요청 (Phase 1+) | `/admin/reports/subject-requests` | ER-470 |

### 2.7 KR 법정 보고서

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-500 | KR 법정 보고서 대시보드 | `/admin/reports/kr-legal` | ER-040~ |
| ERS-510 | 4대보험 신고자료 생성 | `/admin/reports/kr-legal/insurance` | ER-040 |
| ERS-520 | 원천세 신고자료 | `/admin/reports/kr-legal/withholding` | ER-042 |
| ERS-530 | 일용근로자 분기 신고 | `/admin/reports/kr-legal/day-laborer` | ER-044 |
| ERS-540 | 재고 평가 (K-IFRS) | `/admin/reports/kr-legal/valuation` | ER-046 |
| ERS-550 | 월결산 종합 | `/admin/reports/kr-legal/monthly-closing` | ER-048 |

### 2.8 외부 발송 설정 (Super)

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-700 | 화이트리스트 (이메일 / endpoint) | `/super/reports/whitelist` | ER-360 |
| ERS-710 | 이메일 발송자 (DKIM 검증) | `/super/reports/email-senders` | ER-330 |
| ERS-720 | API endpoint (URL + secret) | `/super/reports/api-endpoints` | ER-345 |
| ERS-730 | Slack webhook | `/super/reports/slack-webhooks` | ER-350 |

### 2.9 Super 관리

| ID | 화면명 | 라우트 | 주 룰 |
|---|---|---|---|
| ERS-900 | feature flag 매트릭스 | `/super/reports/feature-flags` | ER-910 |
| ERS-910 | feature flag 변경 (조직별) | `/super/reports/feature-flags/[org]` | ER-940 |
| ERS-920 | KR 법정 보고서 시드 | `/super/reports/seed-kr-legal` | ER-960 |
| ERS-930 | 정의 / 결과 보존 정책 (전사) | `/super/reports/global-retention` | ER-415 |
| ERS-940 | immutable run 삭제 (강화 audit) | `/super/reports/force-purge` | ER-480 |

---

## 3. 권한 매트릭스 (요약)

| 화면 그룹 | L2 | L3 | L4 | Super |
|---|---|---|---|---|
| ERS-001~005 (본인) | ✅ (본인 가능 정의만) | ✅ | ✅ | ✅ |
| ERS-100~140 (정의 관리) | ❌ | ⚠️ (조회) | ✅ | ✅ |
| ERS-150~190 (실행) | ❌ | ✅ | ✅ | ✅ |
| ERS-195 (immutable 재생성) | ❌ | ❌ | ❌ | ✅ |
| ERS-200~240 (스케줄) | ❌ | ✅ | ✅ | ✅ |
| ERS-300~340 (배포) | ❌ | ✅ (마스킹만) | ✅ | ✅ |
| ERS-400~430 (보존) | ❌ | ❌ | ✅ | ✅ |
| ERS-500~550 (KR 법정) | ❌ | ✅ | ✅ | ✅ |
| ERS-700~730 (외부 설정) | ❌ | ❌ | ❌ | ✅ |
| ERS-900~940 (Super) | ❌ | ❌ | ❌ | ✅ |

---

## 4. PII 마스킹 표시 규칙 (UI 공통)

| 보고서 결과 표시 | 권한별 |
|---|---|
| 마스킹 결과 (기본) | L3 |
| 풀 결과 (PII 풀) | L4 |
| 다운로드 마스킹 / 풀 선택 | L4 (둘 다 가능) / L3 (마스킹만) |

---

## 5. 다음 단계 (Phase 2+)

1. 화면 ID 별 명세 파일 (`screens/ERS-XXX.md`)
2. 디자이너 에이전트 호출
3. KR 법정 보고서 양식은 별도 디자인 — 공단 / 국세청 표준 양식 매핑

---

## 6. 참조

- 룰: `../rules/INDEX.md`
- 권한 매트릭스 상위: `../../../rules/permissions.md`
- 외부 모듈 화면: `../../payroll/screens/INDEX.md`, `../../inventory/screens/INDEX.md`, `../../logistics/screens/INDEX.md`
