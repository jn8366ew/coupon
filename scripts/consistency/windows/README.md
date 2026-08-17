# 정합성 — DB/Redis 불일치 주입과 복구 (Windows)

`scripts/consistency/` 의 mac 용 스크립트(bash)를 Windows 환경으로 옮긴 것.
**원본은 건드리지 않았다.**

앞의 세 트랙이 정확성·응답시간·효율을 **재는** 하네스라면, 여기는 재지 않는다.
**두 저장소(DB / Redis)가 어긋난 상태를 일부러 만들고, 그것을 보고, 되돌리는지 검증**한다.
그래서 k6 도 없고 부하 조건도 없다.

| 단계 | 무엇을 하나 | 판정 |
|---|---|---|
| part-5-0 | 두 방향의 불일치를 주입하고 drift 리포트를 본다 | 눈으로 본다 |
| part-5-1 | DLT 에 쌓인 메시지를 replay 해 DB 에 되살린다 | PASS/FAIL |
| part-5-2 | 대사(reconcile)가 Redis 누락은 자동 보정, DB 측은 알람만 내는지 | PASS/FAIL |

**절 번호는 아직 문서에 없다.** 측정 트랙이 아니라 `docs/load-test-*.md` 에 들어가지 않는다.

## 실행 (프로젝트 루트에서)

```powershell
.\scripts\consistency\windows\run.ps1              # 단계 자동 감지
.\scripts\consistency\windows\run.ps1 -Count 3     # 주입 건수 (기본 10)
.\scripts\consistency\windows\run.ps1 -Stage part-5-0   # 감지 무시하고 강제
```

앱이 안 떠 있으면 먼저 띄운다. **이 러너는 빌드하지 않는다** (CLAUDE.md — 태그 선택은 사람 몫).

```powershell
.\build-and-run.ps1 -Tag <태그>            # 새로 만든 코드로
.\build-and-run.ps1 -Tag l1cache -NoBuild  # 예전 이미지로 되돌릴 때는 -NoBuild 필수
```

### 단계 감지

두 곳을 본다.

| 보는 곳 | part-5-1 신호 | part-5-2 신호 |
|---|---|---|
| 소스 | `application/IssuanceDltService.kt` | `batch/Reconciler.kt` |
| 런타임 | `GET /admin/issuance/dlt` | `GET /metrics/reconcile` |

둘이 어긋나면 **DB/Redis 를 건드리기 전에 멈추고** 빌드 커맨드를 안내한다.
"코드는 썼는데 이미지를 안 만들었다" 를 리셋 다음이 아니라 리셋 전에 잡기 위한 것이다
(`docs/architecture.md` §7 의 efficiency 트랙 사례와 같은 이유).

강의를 따라가며 클래스 이름을 다르게 지으면 소스 감지가 못 잡는다. 그때는 `-Stage` 로 지정한다.

## 단계별로 나눠 돌리려면

```powershell
.\scripts\consistency\windows\reset.ps1
$cid = .\scripts\consistency\windows\create-coupon.ps1
.\scripts\consistency\windows\force-dlt.ps1      -CouponId $cid -Count 10
.\scripts\consistency\windows\force-db-only.ps1  -CouponId $cid -Count 10
.\scripts\consistency\windows\drift-report.ps1   -CouponId $cid
```

| 스크립트 | 만드는 상황 | 어긋나는 쪽 |
|---|---|---|
| `force-dlt.ps1` | Redis 는 발급됐는데 DB 저장이 실패 | DB (DLT 재처리 대상) |
| `force-db-only.ps1` | DB 엔 있는데 Redis 발급자 명단이 날아감 | Redis 명단 (대사 보정 대상) |

사용자 ID 구간을 나눠 두었다 — `force-dlt` 는 900001~, `force-db-only` 는 800001~.
같은 쿠폰에 둘 다 주입해도 어느 쪽이 만든 행인지 구분된다.

## 읽는 법 — 여기가 이 트랙에서 제일 중요하다

### `DB 불일치` 는 스케줄러가 켜지는 순간 0 으로 가려진다

drift 리포트의 계산식은 강의 원본과 같다.

```
DB 불일치     = 총 수량 - coupon.issued_quantity - Redis 잔여 재고
사용자 불일치 = 총 수량 - Redis 사용자 수        - Redis 잔여 재고
```

첫 식이 성립하려면 `coupon.issued_quantity` 가 **독립적인 값**이어야 한다.
그런데 이 저장소의 `IssuedQuantitySynchronizer` 는 그 열을 `총 수량 - Redis 잔여 재고` 로
덮어쓴다 (part-4 에서 워커의 `+1` 을 걷어낸 결과). 그게 돌면 위 식은 대입만으로 0 이 되고,
`force-dlt` 로 10건을 넣어도 `=> 정상` 이 찍힌다.

**지금은 안 돈다.** `CouponApplication.kt` 에 `@EnableScheduling` 이 import 만 되어 있고
클래스에 붙어 있지 않아 `@Scheduled` 가 아예 동작하지 않는다. 그래서 강의 원본 계산이
그대로 성립한다 (2026-08-17, `coupon-service:l1cache` 에서 확인).

| 주입 후 | `Redis 잔여 재고` | `Redis 사용자 수` | `(ISSUED n)` | `DB 불일치` | `사용자 불일치` | 판정 |
|---|---:|---:|---:|---:|---:|---|
| `force-dlt` 10건 | 4990 | 10 | 0 | **10** | 0 | DLT 재처리 대상 |
| `force-db-only` 10건 | 4990 | 0 | 10 | 0 | **10** | 대사 보정 대상 |

**`@EnableScheduling` 이 붙는 순간 위 표의 `DB 불일치` 10 이 조용히 0 으로 바뀐다.**
결함이 사라진 게 아니라 파생 열이 가린 것이다. 그래서 `drift-report.ps1` 은
`DB 불일치 = 0` 인데 실제 `ISSUED` 행 수가 모자라면 경고 한 줄을 더 찍는다.

그때는 `db_gap` 을 `issued_quantity` 대신 `ISSUED` 행 수로 계산하도록 바꿔야 한다.
강의 자료의 식과 어긋나게 되므로 지금은 원본 그대로 둔다.

`docs/architecture.md` §6 의 `count_match` 교차 검증도 같은 이유로 현재는 무의미하다
(`issued_quantity` 를 아무도 안 쓰니 항상 0). 이 트랙과는 별개의 이야기지만 같은 뿌리다.

## 알아둘 함정

**`force-dlt` 의 JSON 키와 `IssuanceRequested` 의 필드명은 항상 같이 움직여야 한다 (`issuedAt`).**
한때 앱 필드가 `issueAt` 이라 part-5-1 의 replay 가 `KotlinInvalidNullException` 으로 500 을 냈다.
스크립트가 아니라 **앱 쪽을 `issuedAt` 으로 맞췄다** — 강의를 따라가는 것이 기준이기 때문이다
(`IssuanceRequested.kt`, `CouponService.kt`, `IssuanceTransactionWriter.kt` 세 곳).

바꾼 뒤에는 **DLT 토픽에 남아 있던 예전 메시지가 못 읽힌다.** `run.ps1` 이 part-5-1 시작 시
kafka 를 `--force-recreate` 해서 토픽을 비우므로 보통은 저절로 해결된다.

**Kafka 에 넣을 때 PowerShell 파이프라인을 쓰지 않는다.** 파이프라인은 줄바꿈을 CRLF 로
내보내므로 메시지 값 끝에 `\r` 이 붙는다. 화면상 멀쩡해 보이고 JSON 파싱만 조용히 깨지는
자리라, 페이로드를 base64 로 감싸 컨테이너 안에서 풀어 파이프한다
(`apache/kafka:3.8.0` 은 Alpine 이라 `/bin/base64` 가 있다). 확인:

```powershell
docker compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh `
  --bootstrap-server localhost:9092 --topic issuance.requested.DLT --from-beginning --timeout-ms 5000
```

**`COUPON_RECONCILE_INTERVAL_MS` / `COUPON_RECONCILE_AUDIT_CRON` 은 지금 컨테이너에 안 붙는다.**
`docker-compose.yml` 의 `coupon-service.environment` 에 선언이 없는 이름은 셸 환경변수로 줘도
compose 가 전달하지 않는다. part-5-2 에 들어갈 때 두 줄을 추가해야 한다.

```yaml
      COUPON_RECONCILE_INTERVAL_MS: ${COUPON_RECONCILE_INTERVAL_MS:-}
      COUPON_RECONCILE_AUDIT_CRON: ${COUPON_RECONCILE_AUDIT_CRON:-}
```

`run.ps1` 은 재기동 후 실제로 붙었는지 `docker inspect` 로 보고, 없으면 위 안내를 찍는다
(멈추지는 않는다). "설정을 바꿨으면 적용됐는지 먼저 확인한다" 는 이 저장소의 원칙이다
— `docs/architecture.md` §7.

**`Restart-CouponService` 는 kafka 를 `--force-recreate` 한다.** 볼륨이 없어 **토픽과 오프셋이
통째로 사라진다.** part-5-1/5-2 시작 시점을 깨끗이 하려는 의도지만, 그 전에 주입해 둔 DLT
메시지도 같이 없어진다. part-5-0 은 재기동하지 않으므로 영향이 없다.

**`reset.ps1` 은 Redis 도 비운다(`FLUSHDB`). 빼지 말 것.** TRUNCATE 로 `coupon.id` 가 1 부터
다시 시작하므로, 안 비우면 이전 실행의 `coupon:1:users` 를 물려받아 **주입하지도 않은 불일치**가
집계된다. 이 트랙은 그 숫자를 세는 것이라 곧바로 가짜 결과가 된다.

**`issuance_dlt_log` 는 있을 때만 비운다.** part-5-1 에서 생기는 테이블이라 지금은 없다.
없는 상태로 `TRUNCATE` 하면 리셋 전체가 죽고 그 뒤 라운드가 통째로 안 돈다.
그래서 `information_schema` 로 존재를 먼저 확인한다 (원본 `reset.sh` 와 같은 방식).

**mac 원본은 이 저장소에서 그대로 돌지 않는다.** `scripts/load/part-5/…`, `scripts/load/reset.sh`
같은 강의 저장소 레이아웃을 참조하고, 패키지도 `com.apiece` 이며, `date -u -v+7d` 는 BSD 전용이다.
Windows 판에만 반영되어 있다.

## 파일

| 파일 | 원본 | 하는 일 |
|---|---|---|
| `run.ps1` | `run.sh` + `_common.sh` | 단계 감지 → 시나리오 실행 → 검증 |
| `reset.ps1` | `scripts/concurrency/load/reset.sh` | `coupon`/`issuance`(+있으면 `issuance_dlt_log`) TRUNCATE + `FLUSHDB` |
| `create-coupon.ps1` | (`scripts/load/create_coupon.sh`) | 재고 5000 쿠폰 1개 생성, ID 반환 |
| `drift-report.ps1` | `drift_report.sh` | 지금 얼마나 어긋났는지 출력 |
| `force-dlt.ps1` | `force_dlt.sh` | DB 저장 실패 상황 주입 |
| `force-db-only.ps1` | `force_db_only.sh` | Redis 명단 누락 상황 주입 |

`_common.ps1` 은 만들지 않았다. 이 저장소는 트랙마다 헬퍼를 **일부러 복제**하고
(`docs/architecture.md` §6), 원본에서도 `_common.sh` 를 쓰는 것은 `run.sh` 하나뿐이라
그 안에 함수로 인라인했다.
