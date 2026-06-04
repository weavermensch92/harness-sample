# 품목 마스터 (Item Master)

> **ID 범위**: EI-001 ~ EI-099
> **주제**: 품목 (Item / SKU) 정의, 카테고리, 단위, 라이프사이클
> **상위**: `INDEX.md`

---

## TL;DR

- **SKU = 시스템 내 유일 식별자**. 사업장 단위 고유. 대소문자 구분.
- **base_uom (기준 단위)** 필수. 모든 수량은 이 단위로 저장. 표시 단위 (display_uom) 와 분리.
- **카테고리** 트리. 품목은 leaf 카테고리에만 속함.
- **상태 = ACTIVE / DISCONTINUED / DRAFT**. 단방향 전이 (DRAFT → ACTIVE → DISCONTINUED). 삭제는 soft (deleted_at).
- **트레이서빌리티 옵션**: `tracking_mode = NONE / LOT / SERIAL`. LOT/SERIAL 은 `inventory.lot_tracking` 또는 `inventory.serial_tracking` 토글 의존.
- **변경 이력 강제** — name / base_uom / tracking_mode 변경 시 audit + 영향 분석 필요 (기존 movement 정합).

핵심 ID: EI-010 (식별자) / EI-020 (단위) / EI-030 (카테고리) / EI-040 (상태) / EI-050 (추적 옵션)

---

## 1. 식별자 (EI-010 ~ EI-019)

### EI-010. SKU 명명 (MUST)

- **사업장(organization)** 단위 유일
- 영문 대문자 / 숫자 / 하이픈만 (UPPER-DIGIT-DASH)
- 길이 4~50자
- 변경 불가 (한 번 INSERT 후 UPDATE 금지). 재명명 필요 시 새 item + 구 item DISCONTINUED.

```
✅ COKE-355ML-CAN
✅ STEEL-PIPE-A-1000
❌ Coke 350ml (소문자, 공백)
❌ 콜라350 (한글)
```

### EI-011. 외부 식별자 (SHOULD)

- `barcode` (UPC/EAN/KAN, 8/12/13/14자리) — UNIQUE 권장
- `external_code` (조직 외부 시스템 매핑) — 옵션
- 한국 KAN-13 표준은 880 prefix

barcode 는 UNIQUE 권장이나, 조직별로 같은 외부 EAN 을 다른 SKU 로 관리할 수 있어 (org, barcode) 조합 UNIQUE.

### EI-015. ID 발급 정책

- DB UUID PK (불변)
- SKU = 비즈니스 키 (사용자 노출 / 외부 연동)
- 둘 다 보존 — UUID 로 join, SKU 로 조회

---

## 2. 단위 (EI-020 ~ EI-029)

### EI-020. base_uom 의무 (MUST)

모든 품목은 **기준 단위 1개** 보유. 수량은 항상 base_uom 으로 저장.

```sql
ALTER TABLE inventory_items
  ADD COLUMN base_uom VARCHAR(10) NOT NULL;  -- 'EA', 'KG', 'L', 'M', 'BOX'
```

표준 단위 (조직별 확장 가능):
- 개별: `EA` (각), `BOX` (박스), `CASE` (케이스), `PACK` (팩)
- 무게: `G`, `KG`, `TON`
- 부피: `ML`, `L`, `M3`
- 길이: `MM`, `CM`, `M`
- 면적: `M2`

### EI-021. UOM 변환 (MUST)

표시 단위 ↔ 기준 단위 변환은 별도 테이블:

```sql
CREATE TABLE inventory_uom_conversions (
  item_id      UUID NOT NULL,
  display_uom  VARCHAR(10) NOT NULL,
  base_uom     VARCHAR(10) NOT NULL,
  factor       NUMERIC(14, 6) NOT NULL,  -- 1 display_uom = factor base_uom
  -- 예: 1 BOX = 24 EA  → display_uom='BOX', factor=24
  PRIMARY KEY (item_id, display_uom)
);
```

UI 입력 시 항상 변환 후 base_uom 으로 movement / balance 기록. 표시는 역변환.

### EI-022. 변환 정밀도 (MUST)

- factor 는 NUMERIC(14, 6) — 6자리 소수점
- 변환 후 잔여 소수점은 **base_uom 의 자연 정밀도** 로 반올림
  - EA / BOX / CASE 등 정수 단위 → 소수점 0자리 (rounding 시 알림)
  - KG / L 등 → NUMERIC(14, 4)

### EI-024. 물리 속성 — 무게 / 부피 / 차원 (SHOULD, v0.2)

logistics 적재 검증 (EL-160) / 운임 산정 (EL-420) 정합용. NULL 허용 — 데이터 없으면 logistics 측에서 검증 skip + 경고.

| 컬럼 | 타입 | 단위 | 비고 |
|---|---|---|---|
| `weight` | NUMERIC(10, 2) | weight_uom | 단일 단위 무게 |
| `weight_uom` | VARCHAR(10) | — | `kg` (기본) / `g` / `lb` / `oz` / `t` |
| `volume` | NUMERIC(10, 2) | volume_uom | 단일 단위 부피 |
| `volume_uom` | VARCHAR(10) | — | `m3` (기본) / `l` / `ml` / `cm3` |
| `dim_length_cm` | NUMERIC(10, 2) | cm | 가로 (운송 적재 모델링) |
| `dim_width_cm` | NUMERIC(10, 2) | cm | 세로 |
| `dim_height_cm` | NUMERIC(10, 2) | cm | 높이 |

검증 (DB CHECK):
- 양수 (NULL 허용)
- weight ↔ weight_uom 둘 다 있거나 둘 다 NULL
- volume ↔ volume_uom 동일
- weight_uom / volume_uom 화이트리스트

logistics 측 활용:
- 적재 한도 검증 (`driver_vehicle.md` EL-160) — vehicle.capacity_weight / volume 비교
- 운임 산정 (`shipping_cost.md` EL-420) — tariff 매칭 (weight_min/max / volume_min/max)

NULL 처리 정책:
- weight NULL → logistics 적재 검증 skip + 경고 로그
- volume NULL → logistics 운임 부피 단가 무시 (base_price 만 적용)

데이터 백필 (운영):
- 외부 시스템에서 import (Phase 1+)
- 운영자 수동 입력 (Super 관리 화면)

### EI-025. base_uom 변경 금지 (MUST)

이미 movement / balance 가 있는 품목의 base_uom 변경 = 금지. 모든 과거 데이터 재계산 위험.

변경 필요 시:
1. 기존 item DISCONTINUED
2. 새 SKU + 새 base_uom 등록
3. 잔여 재고는 IN movement 로 새 SKU 에 이전

---

## 3. 카테고리 (EI-030 ~ EI-039)

### EI-030. 트리 구조 (MUST)

- 카테고리는 트리 (parent_id self-FK)
- 깊이 제한: 최대 5단계 (한국 ERP 통상 — 대분류 / 중분류 / 소분류 / 세분류 / 변형)
- 품목은 **leaf 카테고리에만** 배정 — 중간 노드 직접 배정 금지

### EI-031. 변경 (MUST)

- 카테고리 트리 변경 (이동 / 병합) = L4 권한
- 품목 카테고리 재배정 = L3 권한 + audit
- 카테고리 삭제 = soft (`deleted_at`), 자식 노드 / 품목이 있으면 차단

### EI-035. 사업장 공통 vs 개별

- 조직 단위 카테고리 마스터 1개 (전체 사업장 공유)
- 사업장(facility) 별 별도 카테고리 X — 단순화. 필요 시 카테고리에 facility 태그 추가.

---

## 4. 상태 / 라이프사이클 (EI-040 ~ EI-049)

### EI-040. 상태 머신 (MUST)

```
DRAFT  →  ACTIVE  →  DISCONTINUED
   ↓                       ↓
   └────────  (취소) ────→ DELETED (soft)
```

- `DRAFT`: 등록 진행 중. 재고 movement INSERT 차단.
- `ACTIVE`: 정상. movement / 거래 가능.
- `DISCONTINUED`: 신규 입고 차단. 잔여 출고 / 조정만 허용. 잔고 0 도달 후에도 이력 보존.
- `DELETED`: soft. 조회만 가능.

역방향 전이 금지 (DISCONTINUED → ACTIVE 불가).

### EI-041. DISCONTINUED 시 검증 (MUST)

전이 시:
- 미해소 예약 (reservation) 있으면 차단 → 예약 해제 후 재시도
- 잔고 > 0 이면 경고 (block 은 아님 — 잔여 출고 정상)

### EI-045. soft delete (MUST)

- `deleted_at TIMESTAMPTZ` — NULL 이면 활성
- 모든 SELECT 는 기본 `WHERE deleted_at IS NULL` 적용
- 복구는 별도 admin API (audit)

---

## 5. 추적 모드 (EI-050 ~ EI-069)

### EI-050. tracking_mode 선택 (MUST)

```sql
ALTER TABLE inventory_items
  ADD COLUMN tracking_mode VARCHAR(10) NOT NULL DEFAULT 'NONE';
-- 'NONE' / 'LOT' / 'SERIAL'
```

| 모드 | 의미 | 적용 예 |
|---|---|---|
| `NONE` | 단순 수량만 | 원자재, 일반 소모품 |
| `LOT` | 로트(배치) 단위 추적 | 식품, 의약품, 화장품 (KR 의무) |
| `SERIAL` | 개별 시리얼 단위 | 가전, 의료기기, 고가 자산 |

### EI-051. 모드 변경 (MUST)

- DRAFT → ACTIVE 직전까지만 변경 가능
- ACTIVE 이후 변경 = 사실상 금지 (모든 movement 데이터 변경 발생)
- 강제 변경 필요 시 EI-025 와 동일 (새 SKU 신규)

### EI-055. 게이트 토글 (MUST)

- `tracking_mode = LOT` → `inventory.lot_tracking` 토글 ON 필수
- `tracking_mode = SERIAL` → `inventory.serial_tracking` ON 필수
- 토글 OFF 인 조직에서 LOT/SERIAL 모드로 INSERT 시도 = 거부

상세 처리: `lot_tracking.md` (EI-300~)

---

## 6. 가격 / 단가 (EI-070 ~ EI-079)

### EI-070. 표준 단가 (옵션)

품목 마스터에는 **참조용 단가 1개** 만 보관 (구매 / 판매 단가는 별도 모듈).

```sql
ALTER TABLE inventory_items
  ADD COLUMN reference_price NUMERIC(14, 0);  -- KRW 정수, 참조용
```

실제 구매 / 판매 / 평가 단가는 별도:
- 구매: 구매 발주 / 매입 (Phase 1+)
- 판매: 가격 마스터 (외부)
- 평가: `inventory_valuations` (`valuation.md` EI-600~)

### EI-075. 가격 변경 (참고)

reference_price 변경은 자유 (audit 기록), movement / 평가에 영향 X (별도 모듈 사용).

---

## 7. 권한 (EI-080 ~ EI-089)

| 작업 | L1 | L2 | L3 | L4 | Super |
|---|---|---|---|---|---|
| 품목 조회 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 품목 신규 등록 (DRAFT) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| DRAFT → ACTIVE 전이 | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| 카테고리 재배정 | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| ACTIVE → DISCONTINUED | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| soft delete | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| tracking_mode 변경 (DRAFT 한정) | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| barcode / SKU 변경 | ❌ | ❌ | ❌ | ⚠️ | ⚠️ |

---

## 8. 감사 (EI-090 ~ EI-099)

| action | 시점 |
|---|---|
| `inventory.item.created` | 신규 등록 (DRAFT) |
| `inventory.item.activated` | DRAFT → ACTIVE |
| `inventory.item.discontinued` | ACTIVE → DISCONTINUED |
| `inventory.item.deleted` | soft delete |
| `inventory.item.category_changed` | 카테고리 재배정 |
| `inventory.item.tracking_mode_changed` | 추적 모드 변경 (DRAFT) |

---

## 9. 참조

- 추적 상세: `lot_tracking.md` (EI-300~)
- 잔고 영향: `stock_balance.md` (EI-200~)
- 평가: `valuation.md` (EI-600~)
- 게이트 토글: `feature_flags.md` (EI-900~)
- 스키마: `../schemas/tables/inventory_items.sql`
