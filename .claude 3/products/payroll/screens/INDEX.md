# Payroll Screens — 인덱스 (프레임)

> **상위**: `../CLAUDE.md`
> **상태**: Phase 0 — **목록과 라우팅 / 권한 매핑까지만**. 실제 화면 구현 / 디자인은 Phase 2+ (디자이너 에이전트 핸드오프).
> **참조**: `../../../skills/designer/`, `../rules/INDEX.md`

---

## 0. 적용 정책

이 INDEX 는 화면 **목록과 의도** 만 정의. 실제 React 컴포넌트 / 디자인 토큰 / 인터랙션 명세는 Phase 2+ 에서:

1. 이 INDEX 의 화면 ID 별로 디자이너 에이전트 호출 (`skills/designer/prompts/{form,list-page,dashboard}.md`)
2. `frontend-developer` 가 디자인 산출물 → React 구현 (`skills/frontend-developer/`)
3. QA 시나리오 작성 (`skills/qa-engineer/scenarios/permission-matrix.md` 의 Payroll 행 참조)

**Phase 0 의 화면 작성 금지 (MUST)** — 코드 짜지 말고 사양만. 룰 / 스키마 검증이 우선.

---

## 1. 화면 ID 네임스페이스

화면 ID = `EPS-xxx` (Payroll Screens). 룰 ID (EP-xxx) 와 구분.

| 범위 | 주제 | 우선순위 |
|---|---|---|
| EPS-001~009 | 본인 근태 | P0 (필수) |
| EPS-010~019 | 본인 급여 / 명세서 | P0 (필수) |
| EPS-100~119 | 팀원 근태 (L2+) | P1 |
| EPS-200~219 | 급여 계산 / 확정 (L3+) | P1 |
| EPS-300~319 | 지급 승인 / 실행 (L4) | P1 |
| EPS-400~419 | 보수 설정 / 수당 / 공제 설정 (L3+) | P2 |
| EPS-500~519 | 대시보드 / 보고서 (L3+) | P2 |
| EPS-600~619 | Super 관리 (요율 / 어댑터 설정) | P3 |

---

## 2. 화면 목록

### 2.1 본인 영역 (L1+ 필수, 모바일 우선)

| ID | 화면명 | 라우트 | 주 룰 | 비고 |
|---|---|---|---|---|
| EPS-001 | 출퇴근 기록 | `/me/attendance` | EP-001~030 | 모바일, 게이트 / 비콘 백업 |
| EPS-002 | 본인 근태 캘린더 | `/me/attendance/calendar` | EP-050 | 월별, 결근/지각 파생 표시 |
| EPS-003 | 보정 신청 | `/me/attendance/correction` | EP-060 | 누락 / 오기록 신청 |
| EPS-010 | 본인 급여 명세서 목록 | `/me/payslips` | EP-400~440 | 월별, PDF 다운로드 |
| EPS-011 | 명세서 상세 (HTML 뷰어) | `/me/payslips/[id]` | EP-410 | 11항목 강제 |
| EPS-012 | 본인 지급 이력 | `/me/payments` | EP-590 | 마스킹 해제 |

### 2.2 팀 / 관리 영역 (L2 / L3 / L4)

| ID | 화면명 | 라우트 | 주 룰 | 권한 |
|---|---|---|---|---|
| EPS-100 | 팀원 근태 일별 | `/manage/attendance/daily` | EP-080 | L2+ |
| EPS-101 | 팀원 근태 보정 승인 | `/manage/attendance/corrections` | EP-060 | L2+ (팀 한정) |
| EPS-102 | 팀원 근태 직접 입력 | `/manage/attendance/manual` | EP-015 | L3+ |
| EPS-200 | 월별 급여 계산 (DRAFT) | `/manage/payroll/calculate` | EP-262, EP-265 | L3+ |
| EPS-201 | 급여 계산 결과 (DRAFT 검토) | `/manage/payroll/[month]/draft` | EP-260 | L3+ (마스킹 해제) |
| EPS-202 | 급여 확정 (FINALIZED 승인) | `/manage/payroll/[month]/finalize` | EP-270 | L4 |
| EPS-203 | 정정 / VOIDED 처리 | `/manage/payroll/[month]/void` | EP-140, EP-451 | L4 |
| EPS-300 | 지급 일괄 승인 | `/manage/payments/[month]` | EP-510, EP-590 | L4 |
| EPS-301 | 지급 결과 모니터링 | `/manage/payments/monitor` | EP-525 | L4 |
| EPS-302 | PENDING_VERIFICATION 해소 | `/manage/payments/pending` | EP-570 | L4 |
| EPS-303 | 환수 일정 관리 | `/manage/payments/clawback` | EP-560 | L4 |

### 2.3 설정 영역 (L3+)

| ID | 화면명 | 라우트 | 주 룰 | 권한 |
|---|---|---|---|---|
| EPS-400 | 보수 설정 (사용자별 / 시점별) | `/manage/compensation` | EP-200~210 | L3+ (반려), L4 (승인) |
| EPS-410 | 수당 설정 (조직 / 팀 / 사용자) | `/manage/allowances/settings` | EP-340 | L3+ |
| EPS-420 | 임의 공제 설정 (대출 / 노조비) | `/manage/deductions/settings` | EP-388 | L3+ |
| EPS-430 | 휴일 캘린더 | `/manage/holidays` | EP-331 | L3+ (Phase 2+) |

### 2.4 대시보드 / 보고서 (L3+)

| ID | 화면명 | 라우트 | 주 룰 | 권한 |
|---|---|---|---|---|
| EPS-500 | 인건비 추이 (월별) | `/manage/dashboard/labor-cost` | EP-260 | L3+ |
| EPS-501 | 시간외 / 야간 / 휴일 추이 | `/manage/dashboard/overtime` | EP-310 | L3+ |
| EPS-502 | 부서별 인건비 비교 | `/manage/dashboard/by-team` | EP-260 | L4 |
| EPS-503 | 4대보험 / 세금 합계 (월별) | `/manage/dashboard/deductions` | EP-390 | L4 |
| EPS-504 | 미수신 명세서 추적 | `/manage/dashboard/payslip-ack` | EP-462 | L3+ |

### 2.5 Super 관리 (Super 전용)

| ID | 화면명 | 라우트 | 주 룰 | 비고 |
|---|---|---|---|---|
| EPS-600 | 4대보험 / 소득세 요율 관리 | `/admin/deduction-rates` | EP-360 | 연 1회 갱신 |
| EPS-601 | 간이세액표 관리 | `/admin/income-tax-table` | EP-380 | 연 1회 갱신 |
| EPS-602 | 최저임금 정책 | `/admin/minimum-wage` | EP-240 | 연 1회 갱신 |
| EPS-603 | 은행 어댑터 설정 | `/admin/bank-providers` | EP-540 | mock / firmbanking 등 |
| EPS-604 | 명세서 보관 정책 | `/admin/payslip-retention` | EP-435 | 보관 기간 / 자동 삭제 |

---

## 3. 권한 매트릭스 요약

화면 단위 게이트는 `../../../rules/permissions.md` 의 매트릭스 우선. 화면별 상세는 Phase 2+ 에서 각 화면 명세 (`screens/EPS-xxx.md`) 작성 시 정의.

| 영역 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 본인 (2.1) | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| 팀 근태 (2.2 EPS-100~102) | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| 급여 계산 (2.2 EPS-200~203) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 지급 (2.2 EPS-300~303) | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 설정 (2.3) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| 대시보드 (2.4) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Super 관리 (2.5) | ❌ | ❌ | ❌ | ❌ | ✅ |

---

## 4. 마스킹 적용 화면 (MUST)

다음 화면은 표시 직전 `maskField()` 강제 (E-420 / EP-150):

- EPS-101 (팀원 근태 + 급여 정보 노출 시)
- EPS-201 / EPS-202 / EPS-203 (급여 계산 결과 — L2 가 봐도 금액 마스킹)
- EPS-301 / EPS-302 (지급 결과 — 계좌번호 마스킹)
- EPS-500 ~ EPS-503 (집계는 마스킹 해제, 개별 사용자 drilldown 은 권한 검사)

---

## 5. 모바일 우선 화면 (SHOULD)

현장 작업자 (L1) 가 주 사용자인 화면:
- EPS-001 (출퇴근) — PWA / 네이티브 고려
- EPS-002 (본인 근태)
- EPS-003 (보정 신청)
- EPS-010 / EPS-011 (본인 명세서)

데스크톱 우선:
- EPS-200~302 (관리 화면)
- EPS-500~504 (대시보드)
- EPS-600~604 (Super 관리)

---

## 6. 다음 단계 (Phase 2+)

1. **각 화면 ID 별로 명세 파일 작성** — `screens/EPS-XXX.md`
   - 와이어프레임 / 컴포넌트 트리 / 인터랙션 / 상태
2. **디자이너 에이전트 호출** — `skills/designer/prompts/` 템플릿 활용
3. **frontend-developer 구현** — `skills/frontend-developer/examples/` 패턴 활용
4. **QA 시나리오** — `skills/qa-engineer/scenarios/permission-matrix.md` 에 Payroll 행 추가

---

## 7. v0.11 추가 화면 (일용직 / piecework / feature flag)

게이트 토글:
- 일용직 화면: `payroll.day_laborer` ON 인 조직만 노출
- piecework 화면: `payroll.piecework` ON 인 조직만 노출
- 토글 화면: Super 만 항상 노출

### 7.1 본인 영역 (일용직 한정)

| ID | 화면명 | 라우트 | 주 룰 | 비고 |
|---|---|---|---|---|
| EPS-020 | 당일 일용 명세 | `/me/day/[date]` | EP-775, EP-720 | 일용직 본인, 당일 일급 / 원천징수 표시 |
| EPS-021 | 즉시 지급 확인 | `/me/payments/today` | EP-750 | DAILY/IMMEDIATE 사이클 본인 지급 현황 |

### 7.2 관리자 영역

| ID | 화면명 | 라우트 | 권한 | 주 룰 | 비고 |
|---|---|---|---|---|---|
| EPS-220 | 일용직 등록 / 목록 | `/admin/day-laborers` | L3+ | EP-710 | 일용직 사용자 등록, is_day_laborer 토글 |
| EPS-221 | 일용직 일괄 지급 | `/admin/day-laborers/batch-pay` | L4 | EP-752 | 당일 / 주간 누적 한 번에 지급 |
| EPS-222 | 분기 신고 일괄 | `/admin/day-laborers/quarterly-report` | L4 | EP-770 | 일용근로 지급명세서 CSV / XML 내보내기 |
| EPS-223 | 상용 전환 알림 | `/admin/day-laborers/conversion-alerts` | L4 | EP-711 | 누적 90일 도달 인원 검토 |

### 7.3 업무 단가 마스터 (piecework)

| ID | 화면명 | 라우트 | 권한 | 주 룰 | 비고 |
|---|---|---|---|---|---|
| EPS-440 | task_definitions 목록 | `/admin/payroll/tasks` | L3+ | EP-810 | 사업장 작업 단가 카탈로그 |
| EPS-441 | task 신규 등록 | `/admin/payroll/tasks/new` | L3 | EP-811 | task_code, 단가, 단위, 시점 |
| EPS-442 | task 단가 변경 (새 row) | `/admin/payroll/tasks/[code]/revise` | L3 | EP-812 | UPDATE 금지, 새 effective_from |
| EPS-443 | piecework 작업 이력 | `/admin/payroll/piecework-logs` | L3 | EP-820 | PIECEWORK source work_logs 조회 |
| EPS-444 | 최저임금 미달 알림 | `/admin/payroll/min-wage-shortfalls` | L4 | EP-841 | 보전 수당 자동 생성 검토 |

### 7.4 Feature Flag 관리 (Super)

| ID | 화면명 | 라우트 | 권한 | 주 룰 | 비고 |
|---|---|---|---|---|---|
| EPS-605 | 토글 매트릭스 (조직별) | `/super/feature-flags` | Super | EP-910 | 모든 조직 × 모든 토글 한눈에 |
| EPS-606 | 토글 변경 (조직 단위) | `/super/feature-flags/[org]` | L4/Super | EP-930, EP-931 | reason 입력 강제 |
| EPS-607 | 토글 변경 이력 | `/super/feature-flags/[org]/history` | Super | EP-950 | audit_logs 필터 뷰 |
| EPS-608 | 의존성 그래프 | `/super/feature-flags/dependencies` | Super | EP-940 | 의존 관계 시각화 (Phase 2+) |

### 7.5 우선순위

- P1 (D 트랙 적용 시 필수): EPS-220, EPS-221, EPS-222, EPS-440, EPS-441, EPS-606
- P2: EPS-020, EPS-021, EPS-223, EPS-442, EPS-443
- P3: EPS-444, EPS-605, EPS-607, EPS-608

---

## 8. 참조

- 룰: `../rules/INDEX.md`
- 디자이너 스킬: `../../../skills/designer/`
- 프론트 패턴: `../../../skills/frontend-developer/`
- 권한 매트릭스: `../../../rules/permissions.md`
