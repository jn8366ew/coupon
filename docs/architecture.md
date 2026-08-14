# 구조 안내

이 저장소가 어떻게 조립되어 있는지 한 번에 파악하기 위한 문서.
코드를 처음부터 읽지 않아도 어디에 무엇이 있고 왜 그렇게 되어 있는지 알 수 있게 하는 것이 목적이다.

측정 결과와 그 해석은 [`load-test-k6.md`](load-test-k6.md), 도메인 정의는
[`domain-model.md`](domain-model.md), 테이블 정의는 [`db-schema.md`](db-schema.md) 에 있다.
여기서는 그 숫자들을 다시 적지 않고 가리키기만 한다.

기준 시점: 2026-08-15, `coupon-service:kafka` 측정 직후 (`kafka-restore` 수정 반영).

---

## 1. 이 프로젝트의 성격

선착순 쿠폰 발급에서 생기는 **동시성 결함을 일부러 재현하고, 구현을 바꿔가며 측정·비교하는 학습 프로젝트**다.
프로덕션 코드가 아니다. 그래서 몇 가지가 의도적으로 "덜 되어" 있다.

- 인증이 없다. 사용자는 `X-User-Id` 헤더로 그냥 받는다
- `ddl-auto: update` 로 스키마를 만든다
- `application.yaml` 이 쿼리 로그를 켜 두고 있다 (개발 중 SQL 을 보려고)

**구현 전환은 브랜치가 아니라 이미지 태그로 한다.** `naive`, `pessimistic`, `lua`,
`lua-fix`, `lua-gate`, `lua-wb`, `lua-pool`, `queue-mem`, `kafka` 를 같은 소스 트리에서 번갈아 빌드해
태그만 다르게 붙인다 (각각이 무엇인지는 §5). 브랜치로 나누면 스크립트·문서를 고칠 때마다
여러 곳에 포팅해야 하고, 서로 다른 하네스로 잰 수치는 비교가 성립하지 않기 때문이다.

```powershell
.\build-and-run.ps1 -Tag pessimistic     # 빌드해서 그 태그로 띄운다
.\build-and-run.ps1 -Tag naive -NoBuild  # 이미 있는 이미지로 전환만 (되돌아갈 때 필수)
```

---

## 2. 요청 흐름

측정 대상은 `POST /api/v1/coupons/{couponId}/issue` 하나다. 나머지 엔드포인트는 준비·확인용이다.

| 엔드포인트 | 파일 | 용도 |
|---|---|---|
| `POST /api/v1/coupons` | `api/CouponController.kt:22` | 쿠폰 생성. 부하 테스트 시작 전에 한 번 |
| `POST /api/v1/coupons/{id}/issue` | `api/CouponController.kt:28` | **측정 대상.** 선착순 발급 |
| `POST /api/v1/issuances/{id}/use` | `api/IssuanceController.kt:18` | 발급분 사용 처리 |
| `GET /api/v1/users/me/issuances` | `api/UserIssuanceController.kt:16` | 내 발급 내역. 헬스체크 대용으로도 쓴다 |

발급 요청이 지나는 길 (`application/CouponService.kt` 의 `issue`):

```
CouponController.issue
  └─ CouponService.issue                    @Transactional
       ├─ couponRepository.findById          SELECT coupon (없으면 COUPON_NOT_FOUND)
       ├─ coupon.isBookingOpen(now)          시작 전이면 NOT_STARTED
       ├─ couponIssuer.tryIssue              Redis Lua — 발급 자격 판정이 여기서 원자적으로 끝난다
       │                                       SOLD_OUT / ALREADY_ISSUED 는 여기서 예외로 끝
       └─ issuanceRequestProducer.publish    Kafka 에 던지고 곧바로 200 을 반환한다
            └─ whenComplete { 실패하면 → couponIssuer.restore }   재고를 되돌린다

  ⤷ IssuanceWorker — @KafkaListener(concurrency=3), 컨슈머 3개가 파티션 하나씩
       └─ IssuanceWriter.write                UNIQUE 위반은 멱등 처리로 삼키고 넘어간다
            └─ IssuanceTransactionWriter.insert               @Transactional
                 └─ issuanceRepository.save                     INSERT issuance 뿐이다
```

**워커에는 `coupon` 행을 건드리는 쿼리가 없다.** 예전에는 여기서 `incrementIssueQuantity` 를
같이 쳤는데, 그 값은 `IssuedQuantitySynchronizer` 가 매초 덮어써서 결과에 기여하지 않으면서
컨슈머들을 단일 행 락에 줄 세우기만 했다. 빼자 부하 종료 후 드레인이 통째로 사라졌다
([`load-test-k6.md` §16](load-test-k6.md)).

**판정은 Redis, 기록은 큐 뒤의 워커** 로 나뉘어 있는 것이 이 구조의 핵심이다.
경합이 몰리는 자리(재고 차감, 1인 1매)는 전부 Redis 의 Lua 스크립트 안에 있고,
DB 쓰기는 응답 경로에서 빠져 있다. 그래서 사용자 응답 p99 가 705ms → 5.95ms 가 됐다
([`load-test-k6.md` §14.2](load-test-k6.md)).

**큐는 이제 JVM 밖에 있다.** Kafka 토픽 `issuance.requested` (파티션 3, 키는 `userId`).
힙 큐 시절의 용량 상한(10,000)과 `TaskRejectedException`(500)은 없어졌다 — 브로커 디스크가
받아 주고, 프로세스가 죽어도 메시지가 남는다. 대신 **파티션 3개가 소비 병렬도의 상한**이고
(`KafkaTopicConfig`), 새 실패 모드가 하나 생겼다 — `publish` 가 실패하면 Redis 재고는
이미 깎인 뒤다. 그래서 `whenComplete` 에서 `restore` 로 되돌린다 (§4).

**중요한 것은 200 OK 가 "발급 완료" 가 아니라 "접수 완료" 라는 점이다.** 응답 본문의
`id` 는 아직 저장 전이라 `null` 이고, 실제 행은 워커가 나중에 쓴다. 5,000건을 다 쓰는 데
**얼마나 뒤에 앉는지는 지금 못 잰다.** `kafka-nocount` 부터는 5,000행이 부하 구간 안에서
다 들어가서, 부하 종료 후 드레인 폴링에 아무것도 안 잡힌다. "≥160/s" 이상은 말할 수 없다
([`load-test-k6.md` §16.2](load-test-k6.md)).

`coupon.issued_quantity` 는 **`IssuedQuantitySynchronizer` 만 쓴다.**
1초마다 `total_quantity − (Redis 재고)` 로 덮어쓴다. 즉 이 열은 "Redis 가 센 발급 수" 이고,
그래서 검증의 `count_match` 가 **Redis 와 DB 의 교차 검증**으로 되살아났다
([`load-test-k6.md` §16.5](load-test-k6.md)).

예외는 전부 `support/DomainException.kt` 의 sealed 계층이고,
`support/GlobalExceptionHandler.kt` 가 RFC 9457 ProblemDetail 로 변환한다.
`code` 프로퍼티에 `SOLD_OUT`, `ALREADY_ISSUED` 같은 식별자가 실린다.

**이 서비스에서 409 는 정상 동작이다.** 재고보다 요청이 많으면 `SOLD_OUT` 이,
1인 1매 정책이 동작하면 `ALREADY_ISSUED` 가 나온다. 부하 테스트에서 200 을 기대하면 안 되는 이유다.

---

## 3. 파일 지도

```
src/main/kotlin/com/example/coupon/
  CouponApplication.kt          진입점
  api/
    CouponController.kt         쿠폰 생성 / 발급
    IssuanceController.kt       발급분 사용
    UserIssuanceController.kt   내 발급 내역 조회
    dto/                        요청·응답 DTO (from() 팩토리로 엔티티 변환)
  application/
    CouponService.kt            발급 흐름. 조회 → 게이트 통과 → 발행하고 즉시 반환
    IssuanceCompensator.kt      깎인 재고를 되돌리는 정책 한 곳. 발행 실패·소비 실패가 같이 쓴다
    CouponIssuer.kt             Redis Lua 호출 래퍼. tryIssue / restore / initStock
    IssuedQuantitySynchronizer.kt  issued_quantity 를 Redis 에서 파생시켜 1초마다 반영
    IssuanceService.kt          사용/조회
  infrastructure/messaging/
    IssuanceTopics.kt           토픽·컨슈머그룹 이름 상수
    IssuanceRequested.kt        발행되는 이벤트 (couponId, userId, 발급/만료 시각)
    IssuranceRequestProducer.kt 프로듀서. future 를 삼키지 않고 그대로 돌려준다 (파일명 오타)
    IssuanceWorker.kt           @KafkaListener(concurrency=3) — write 를 호출한다
    IssuanceWriter.kt           쓰기 진입점. UNIQUE 위반을 멱등 처리로 삼킨다
    IssuanceTransactionWriter.kt  실제 @Transactional 경계. INSERT 하나뿐 (카운터는 안 건드린다)
    KafkaConfig.kt              프로듀서/컨슈머 팩토리. Jackson 3 직렬화, max.block.ms 3초
    KafkaTopicConfig.kt         토픽 선언 (파티션 3 = 소비 병렬도의 상한).
                                  KafkaConfig 가 KafkaAdmin 을 만들어야 동작한다 — §7 함정 참고
    KafkaErrorHandlerConfig.kt  재시도 1초 x 3회 → <topic>.DLT, 그리고 재고 복구
  domain/
    Coupon.kt                   재고 총량 + 발급 카운터
    Issuance.kt                 발급 1건
    IssuanceStatus.kt           ISSUED / USED / EXPIRED
    CouponRepository.kt         비관적 락 버전이 주석으로 보존되어 있다
    IssuanceRepository.kt
  support/
    DomainException.kt          sealed 예외 + HTTP 상태 + code
    GlobalExceptionHandler.kt   ProblemDetail 변환
src/main/resources/
  application.yaml              개발 기본값 (쿼리 로그 켜짐) + Hikari 풀 크기 50
  lua/issue.lua                 Redis 원자 재고 차감
  lua/restore.lua               그 짝. 되돌리기 (SREM 성공 시에만 INCR — 멱등)
```

---

## 4. 데이터 모델과 Redis 키

### `coupon` (`domain/Coupon.kt`)

| 컬럼 | 역할 |
|---|---|
| `total_quantity` | 재고 총량. 부하 테스트에서 5,000 |
| `issued_quantity` | 발급 카운터. **파생 값** — 1초마다 Redis 재고에서 계산해 덮어쓴다 |
| `starts_at` | null 이면 즉시 발급 가능. 부하 테스트는 null |
| `validity_days` | 발급 시 만료일 계산용 |

**선착순이라 모든 요청이 이 테이블의 행 하나를 향한다.** InnoDB 는 그 행의 UPDATE 를 직렬화하므로,
발급 경로에서 이 행에 쓰기를 하는 순간 그것이 처리량의 상한이 된다.
현재 구조가 `issued_quantity` 를 요청 경로에서 올리지 않는 이유가 이것이다
([`load-test-k6.md` §12.4](load-test-k6.md)).

### `issuance` (`domain/Issuance.kt`)

`(user_id, coupon_id)` 에 `uk_issuance_user_coupon` UNIQUE 가 걸려 있다.
애플리케이션 로직이 뚫려도 DB 가 중복 발급을 막는 최후 방어선이다.
그래서 `verify` 의 `duplicate_users` 는 사실상 항상 0 이 나온다 — 이 열이 0 이라고
"중복 방지 로직이 잘 동작한다" 고 읽으면 안 된다.

### Redis

| 키 | 타입 | 누가 만드나 |
|---|---|---|
| `coupon:{id}:stock` | String (정수) | `CouponIssuer.initStock` — 쿠폰 생성 시 `total_quantity` 로 초기화 |
| `coupon:{id}:users` | Set (userId) | `issue.lua` 가 발급 성공 시 `SADD`, `restore.lua` 가 `SREM` |

**재고의 진실은 DB 가 아니라 Redis 에 있다.** `resources/lua/issue.lua` 한 스크립트가
중복 여부와 재고를 함께 판정하고 그 자리에서 차감한다.

Redis 는 싱글 스레드라 **명령 하나는 그 자체로 원자적**이다. 그래서 `DECR` 만 쓸 거면 Lua 가 필요 없다.
문제는 판정이 명령 하나로 안 끝난다는 것이다 — `SISMEMBER` → `GET` → `DECR` → `SADD` 네 단계이고,
그 사이 왕복마다 다른 요청이 끼어들면 같은 사람에게 두 장이 나가거나 재고가 음수가 된다.
Lua 스크립트는 이 여러 명령을 **Redis 서버 안에서 한 덩어리로** 실행해 그 틈을 없앤다.
**Lua 를 쓰는 이유는 속도가 아니라 이 원자성이다.**

Redis 는 DB 트랜잭션 밖이므로 차감 뒤에 무슨 일이 생겨도 저절로 돌아오지 않는다.
보상이 없으면 그 한 장은 아무에게도 가지 않은 채 사라지고, 그 사용자는 `:users` 집합에 남아
다시 시도해도 영영 거절된다. 실제로 `lua` 태그에서 1,000명 시나리오 한 번에 23장이 샜고,
**DB 만 보는 검증은 그것을 OK 로 통과시켰다** ([`load-test-k6.md` §12.2](load-test-k6.md)).
`scripts/response/windows/verify-burst.ps1` 이 매번 Redis 잔여 재고를 같이 출력하는 이유다.

**지금 보상은 발행 실패 경로에만 있다** (`kafka-restore`, [§14.7·§15](load-test-k6.md)).
`CouponService.issue` 가 `publish` 의 future 를 받아 실패하면 `restore.lua` 로 되돌린다.
`restore.lua` 는 `SREM` 이 실제로 지웠을 때만 `INCR` 하므로 두 번 불려도 안전하다.
(`kafka` 태그까지는 이 경로가 없었고, `CouponIssuer.restore` 는 `:issued` 라는
존재하지 않는 키를 지우고 있어 불러도 반쪽만 돌아갔다.)

**소비 실패에도 보상이 붙었다** (`kafka-dlt-restore`, [§17](load-test-k6.md)).
워커가 3회 재시도 끝에 DLT 로 보낼 때 같이 되돌린다. 순서는 **DLT 발행 → 복구** 다.
정책은 `application/IssuanceCompensator` 한 곳에 있고 두 경로가 같이 쓴다.

**아직 안 막힌 자리 둘.** 역직렬화가 실패하면 `couponId` 를 알 수 없어 되돌리지 못한다
(ERROR 로그만 남는다). 그리고 ack 이 애매하게 실패하면 보상이 과잉이 되어 총량을 넘길 수 있다
([`load-test-k6.md` §15.3](load-test-k6.md)).

---

## 5. 구현들의 차이

같은 소스 트리에서 `CouponService.issue` 주변만 바꿔가며 만든다.

| 태그 | 재고 판정 | DB 쓰기 | 정확성 | 처리량 |
|---|---|---|---|---:|
| `naive` | `isSoldOut()` 만 | 동기, 요청마다 `++` (dirty checking) | FAIL — 과발급, 카운터 90% 유실 | ~290/s |
| `pessimistic` | `SELECT … FOR UPDATE` 후 검사 | 동기, 락 안에서 증가 | OK | ~263/s |
| `lua` | Redis Lua 원자 차감 (DB 검사 뒤) | 동기, 원자 UPDATE | OK (단, 재고 누수 있음) | ~285/s |
| `lua-fix` | 위와 같음 + 롤백 시 재고 복구 | 위와 같음 | OK | ~278/s |
| `lua-gate` | Lua 게이트를 DB 접근 **앞으로** | 위와 같음 | OK | ~252/s |
| `lua-wb` | Lua 게이트가 맨 앞 | 동기 INSERT, 카운터는 write-behind | OK | ~2,700/s |
| `lua-pool` | 위와 같음 | 위와 같음 (Hikari 풀 10 → 50) | OK | ~4,000/s |
| `queue-mem` | 게이트가 DB 조회 **뒤로** 돌아옴 | **인메모리 큐 + 워커 1개 (비동기)** | OK | 응답 5,000/s · 쓰기 ~155/틱 |
| `queue-async` | 위와 같음 | 위와 같음, 단 Spring `@Async` + 이벤트로 | OK | 응답 5,000/s · 쓰기 ~155/틱 |
| `kafka` | 위와 같음 | **Kafka (파티션 3, 컨슈머 3)** | OK (발행 실패 시 유실) | 응답 5,000/s · 쓰기 ~157/틱 |
| `kafka-restore` | 위와 같음 | 위와 같음 + **발행 실패 시 재고 보상** | OK | 응답 5,000/s · 쓰기 ~160/틱 |
| `kafka-nocount` | 위와 같음 | 위와 같음, 단 **워커에서 카운터 UPDATE 제거** | OK | 응답 5,000/s · 쓰기 ≥160/s (상한 미상) |
| **`kafka-dlt-restore` (현재)** | 위와 같음 | 위와 같음 + **소비 실패(DLT)에도 재고 보상** | OK | 위와 같음 |

`pessimistic` 버전의 리포지토리 메서드는 `domain/CouponRepository.kt` 에 주석으로 보존되어 있다.

**이 표에서 읽어야 할 것 둘.**

`lua` → `lua-gate` 까지 처리량이 전혀 안 움직였다. Redis 를 붙여 놓고도 `coupon` 단일 행
UPDATE 를 요청 경로에 남겨 두었기 때문이다. 그 UPDATE 를 빼자(`lua-wb`) 10배가 됐다.
**경합 지점을 DB 밖으로 빼는 것이 Lua 의 값어치인데, DB 쪽 경합을 같이 없애지 않으면
복잡도만 늘고 이득이 없다.**

`queue-async` 는 직접 만든 큐·워커를 Spring 기능으로 갈아끼운 것인데 **수치가 사실상 같다**
(p99 5.62 → 5.59ms). 풀 설정이 앞 구현과 특성이 같으니 그렇다.
**프레임워크로 옮긴 것은 코드가 줄어든 것이지 성능이 달라진 것이 아니다.**

`kafka` 도 같은 성격의 관찰을 하나 더 준다. **큐를 프로세스 밖으로 내보내고 소비자를 3배로
늘렸는데 쓰기 처리량이 155 → 157 로 안 움직였다.** 파티션 쏠림이 아니라는 것은 브로커의
종료 오프셋(33.6 / 33.5 / 32.9%)으로 확인했다. **병목이 큐에도, 소비자 수에도 없다는 뜻이다.**
얻은 것은 성능이 아니라 내구성(프로세스가 죽어도 메시지가 남는다)과 DLT 다.

**그러면 무엇이 잡고 있었나 — `kafka-nocount` 가 답한다.** `incrementIssueQuantity`
(= `coupon` 단일 행 UPDATE) 한 줄을 워커에서 빼자 부하 종료 후 드레인이 통째로 사라졌고,
대신 응답 분포가 med 부터 p99 까지 한 방향으로 밀렸다(1.25 → 1.39ms, 6.45 → 11.74ms).
둘 다 **"쓰기가 빨라져 부하 구간 안으로 들어왔다"** 하나로 설명된다.

**`lua-wb` 에서 10배를 만들어 준 그 쿼리가 자리만 바꿔 워커 안에 다시 들어와 있었던 것이다.**
경합 지점은 옮겨도 없어지지 않는다 — 어디에 있든 단일 행 UPDATE 는 그 경로의 상한이다.
큐가 한 일은 그것을 **사용자 응답 밖으로** 옮긴 것까지다.

자세한 분석은 [`load-test-k6.md` §12](load-test-k6.md)(동기 구현들),
[§13](load-test-k6.md)(큐 디커플링), [§14–16](load-test-k6.md)(Kafka·병목 확정).

---

## 6. 부하 테스트 하네스

**하네스는 두 트랙이다.** 재는 것이 다르면 시나리오도 검증도 달라야 하기 때문이다.

| 트랙 | 재는 것 | 한 줄 실행 |
|---|---|---|
| `scripts/concurrency/` | 정확성 — 과발급·중복발급·카운터 일치 | `.\scripts\concurrency\windows\load-test.ps1 <시나리오>` |
| `scripts/response/` | 응답시간 — `issue_latency` 분포(P99), 부하 전달률 | `.\scripts\response\windows\run.ps1` |

각 트랙 안에서 Windows 판은 `<트랙>/windows/`, mac 원본(bash + 로컬 k6)은 `<트랙>/load/` 또는
트랙 루트에 있다. **mac 판은 수정하지 않는다.** 두 판본의 부하 조건(rate, VU, USER_POOL)이
같아야 결과를 비교할 수 있고, 실제로 두 트랙도 같은 조건을 쓴다
(`constant-arrival-rate` 5,000/s × 30s, USER_POOL 20,000, 재고 5,000).

### 역할 분담

| 스크립트 | 하는 일 |
|---|---|
| `build-and-run.ps1` | jib 로 이미지 빌드 → `docker load` → 태그를 `.env` 에 기록 → compose 기동 |
| `concurrency/windows/load-test.ps1` | 쿼리 로그 끄기 → 리셋 → 쿠폰 생성 → k6 → 카운터 동기화 대기 → 검증 |
| `response/windows/run.ps1` | 위와 같되 **워밍업 1회 + 본 측정 1회**, 검증은 드레인 폴링 |
| `<트랙>/windows/reset.ps1` | `coupon` / `issuance` TRUNCATE + Redis `FLUSHALL` |
| `<트랙>/windows/create-coupon.ps1` | 쿠폰 1개 생성하고 ID 를 표준출력으로 반환 |
| `concurrency/windows/verify.ps1` | 판정 SQL 실행 → 과발급/카운터 일치 여부 출력 |
| `response/windows/verify-burst.ps1` | 쓰기가 멈출 때까지 폴링 → 위 판정 + **Redis 잔여 재고** |
| `<트랙>/windows/k6/*.js` | k6 시나리오 |

`reset.ps1` / `create-coupon.ps1` 은 두 트랙에 **일부러 복제**해 두었다. 한쪽 하네스를 고치다
다른 쪽 측정 조건이 조용히 바뀌는 것을 막기 위해서다.

### 응답시간 트랙에만 있는 것

- **워밍업 라운드.** 1회차는 버린다. JIT·Hikari 풀이 데워지는 비용이 섞이기 때문이다.
  실측으로 1회차 p99 102.93ms → 2회차 5.61ms 로 18배 차이가 났다
- **드레인 폴링.** 큐 구현에서는 k6 이 끝나도 워커가 계속 쓴다. `issuance` 행 수가 멈출 때까지
  기다린 뒤 검증한다. 이 폴링이 끝난 뒤에 다음 라운드의 리셋이 돌므로 라운드끼리 안 섞인다
- **`status 0` 을 지연 분포에서 제외.** 연결 거부는 `duration ≈ 0ms` 로 기록돼 p99 를
  실제보다 좋게 만든다. `status_conn_error` 로 따로 세고 같이 읽는다
  ([`load-test-k6.md` §13.2](load-test-k6.md))

### compose 구성 (`docker-compose.yml`)

- `mysql` 8.4, `redis` 8.0 (AOF 켜짐), `kafka`, `coupon-service`, `k6`
- `kafka` 는 `apache/kafka:3.8.0` 을 **KRaft 모드**로 띄운다 — ZooKeeper 컨테이너가 없다.
  볼륨을 안 붙였으므로 `docker compose down` 하면 토픽과 오프셋이 같이 사라진다.
  `coupon-service` 가 `condition: service_healthy` 로 기다리므로 기동이 그만큼 늦다
- `coupon-service` 의 이미지 태그는 `${COUPON_IMAGE_TAG:-latest}` — `.env` 에서 온다
- `k6` 는 `profiles: ["load"]` 라 평소 `up -d` 에는 뜨지 않고,
  `docker compose run --rm k6 …` 로 명시 실행할 때만 뜬다.
  앱과 같은 네트워크 안이라 `http://coupon-service:8080` 으로 직접 붙는다
  (Windows 의 localhost 포트포워딩을 안 거친다)
- `docker-compose.loadtest.yml` 은 측정 시 쿼리 로그를 끄는 override

### 검증 기준

| 컬럼 | 뜻 |
|---|---|
| `over_issuance` | `issuance_rows > total_quantity` → FAIL. 전역 N장 보장이 깨짐 |
| `count_match` | `issued_quantity = issuance_rows`. **다시 의미가 있다** — 아래 참고 |
| `duplicate_users` | 같은 사용자가 2장 이상 받은 수 (UNIQUE 때문에 항상 0) |

`count_match` 는 한동안 의미가 없었다. `queue-mem` ~ `kafka` 에서는 워커의 상대적 `+1` 과
동기화기의 절대 덮어쓰기가 같은 열을 건드려서, 드레인 후 수렴한 값을 볼 뿐이었다.
**`kafka-nocount` 에서 워커의 `+1` 을 빼면서 되살아났다** — 이제 `issued_quantity` 는
`IssuedQuantitySynchronizer` 만 쓰는 "Redis 가 센 발급 수" 이므로, 이 비교는
**Redis 와 DB 의 교차 검증**이다. FAIL 이 뜨면 진짜 신호다.

**이 검증만으로는 부족하다.** 세 컬럼 모두 DB 안에서만 계산되므로,
Redis 재고가 새는 과소발급을 잡지 못한다 (실제로 놓친 적이 있다 —
[`load-test-k6.md` §12.2](load-test-k6.md)). 그래서 응답시간 트랙의 `verify-burst.ps1` 은
`coupon:{id}:stock` 이 `total_quantity − 발급 수` 와 맞는지 매번 같이 출력한다.
정확성 트랙에서 재고를 직접 보려면:

```powershell
docker compose exec redis redis-cli GET coupon:1:stock
```

---

## 7. 알아둘 함정

여기 적힌 것들은 전부 한 번씩 당하고 나서 대응해 둔 것이다. 되돌리지 말 것.

**`jibDockerBuild` 를 쓰지 않는다.** Jib 3.4.4 가 `docker info` 에서 교착에 빠져 무한정 멈춘다.
`jibBuildTar` + `docker load` 조합으로 우회한다 → [`jib-docker-build-troubleshooting.md`](jib-docker-build-troubleshooting.md)

**빌드할 때 `-Djib.to.tags` 를 반드시 함께 넘긴다.** `build.gradle.kts:64` 의
`tags = setOf(project.version.toString())` 가 살아 있어, 그냥 빌드하면 새 이미지가
`coupon-service:0.0.1-SNAPSHOT` 태그까지 가져가면서 기존 이미지를 가리키던 태그가 새 것으로 옮겨간다.
비교 기준을 잃는다. `build-and-run` 이 이미 처리하고 있다.

**태그를 셸 환경변수가 아니라 `.env` 파일에 쓴다.** 셸 변수는 셸을 벗어나면 사라지는데,
`load-test.ps1` 이 로그 설정 때문에 컨테이너를 재생성할 때 조용히 기본 태그로 되돌아간다.
`.env` 는 compose 가 자동으로 읽으므로 PowerShell / Git Bash 어디서 부르든 일관된다.

**이전 구현으로 되돌아갈 때는 `-NoBuild` 를 반드시 준다.** 빼면 "현재 소스" 를 빌드해
예전 이름표를 붙이므로, 알맹이는 최신 코드인데 이름만 예전인 이미지가 만들어지고
진짜 예전 이미지는 사라진다.

**쿼리 로그는 Spring 프로파일이 아니라 환경변수로 끈다.** 프로파일 파일은 이미지에 구워지므로
고칠 때마다 재빌드해야 하고, 재빌드를 잊으면 "프로파일은 활성인데 설정은 안 먹은" 상태가 된다.
로그는 계속 찍히는데 겉보기엔 정상이라 **조용히 틀린 측정**을 하게 된다.
환경변수는 `docker inspect` 로 실제 반영 여부를 확인할 수 있어 그 함정이 없다.
`load-test.ps1` 이 매번 확인하고, 안 되어 있으면 측정하지 않고 멈춘다.
(로그가 성능 병목이라는 가설은 세웠다가 기각됐다 — [`load-test-k6.md` §7](load-test-k6.md))

**설정을 바꿨으면 적용됐는지 먼저 확인하고 나서 측정한다.** 위 두 항목(로그·태그)과 같은 원칙이고,
이 프로젝트에서 가장 자주 당한 실패 모드다. 확인 방법은 설정마다 다르다.

| 바꾼 것 | 확인 |
|---|---|
| 쿼리 로그 | `docker inspect` 로 컨테이너 환경변수 (`load-test.ps1` 이 자동으로 한다) |
| 이미지 태그 | 측정 시작 시 출력되는 `측정 대상 이미지: coupon-service:...` |
| Hikari 풀 크기 | `SHOW GLOBAL STATUS LIKE 'Max_used_connections'` — 풀 50 이면 51 정도가 나온다 |

**k6 검사에 `status !== 0` 이 필요하다.** 연결 실패 시 k6 의 `res.status` 는 0 인데
`0 !== 404` 는 참이라 404 검사만으로는 통과해 버린다. 요청의 66% 가 앱에 닿지도 않았는데
`checks 100%` 가 뜨는 상황이 실제로 있었다 → [`load-test-k6.md` §8.2](load-test-k6.md)

**`reset.ps1` 은 Redis 도 `FLUSHALL` 한다. 빼지 말 것.** TRUNCATE 로 `coupon.id` 가 1부터
다시 시작하므로, 비우지 않으면 이전 실행이 남긴 `coupon:1:users` 집합을 그대로 물려받아
두 번째 실행부터 모든 요청이 "이미 발급" 으로 튕긴다(발급 0건). 재고 키만 쓰던 시절에는
`initStock` 이 덮어써 줘서 이 문제가 드러나지 않았다.

**측정 중에 `coupon-service` 컨테이너를 재시작하지 않는다 — 다만 위험의 방향이 뒤집혔다.**
인메모리 큐 시절에는 재시작하면 큐에 남은 이벤트가 통째로 사라져 **과소발급**이 됐다.
Kafka 는 반대다. **메시지가 남는다.** 그래서 이제 위험은 유실이 아니라 **오염**이다 —
드레인이 안 끝난 채 리셋(TRUNCATE + `FLUSHALL`)하면, 다음 라운드에서 컨슈머가 이전 라운드
메시지를 마저 먹고 새 `coupon.id=1` 에 행을 쓴다. **`reset.ps1` 은 토픽을 비우지 않는다.**
지금은 `verify-burst.ps1` 의 드레인 폴링이 매 라운드 토픽을 다 비우고 나서 다음 리셋이
돌기 때문에 안 터진다. 폴링을 건드리거나 타임아웃(60초)에 걸리면 그 보호가 사라진다.
`response/windows/run.ps1` 이 k6 을 `docker compose run --rm --no-deps` 로 부르는 이유가
이것이다 — `--no-deps` 가 없으면 compose 가 `depends_on` 을 따라 앱 컨테이너를 건드릴 수 있고,
그러면 큐가 비워지는 데다 워밍업으로 데운 JVM 도 식는다. 스크립트가 끝에 컨테이너 ID 를
대조해 재생성 여부를 알려준다.

**k6 의 종료 코드로 threshold 를 판정하지 않는다.** p(99)=5.62ms, 최댓값 46.59ms 인 실행이
`thresholds have been crossed` 를 찍고 exit 99 로 끝난 적이 있다. 그 분포로는 어떤 시점에도
500ms 를 넘길 수 없으므로 종료 코드 쪽이 틀린 것이다 (원인 미확정). 판정은 요약 JSON 의
`metrics.issue_latency.thresholds` 로 한다 (`true` = 넘김, `false` = 통과).
`response/windows/run.ps1` 이 그것을 읽어 출력하고 종료 코드와 어긋나면 알려준다
→ [`load-test-k6.md` §13.2](load-test-k6.md)

**이 프로젝트에는 Kafka 자동설정이 없다. `application.yaml` 의 `spring.kafka.*` 는 거의 다 무시된다.**
`build.gradle.kts` 가 `spring-boot-starter-kafka` 가 아니라 `org.springframework.kafka:spring-kafka` 를
직접 넣었고, Boot 4 부터 자동설정은 기술별 모듈(`spring-boot-kafka`)에 있어 starter 로만 딸려온다.
실제로 `spring-boot-autoconfigure-4.1.0.jar` 안에 kafka 클래스가 하나도 없다.
그래서 `KafkaProperties` 바인딩이 없고, 지금 도는 것은 `KafkaConfig` 가 `bootstrap-servers` 를
`@Value` 로 직접 읽기 때문이다. **설정을 yaml 에 추가해도 조용히 안 먹는다 — `KafkaConfig` 를 고쳐야 한다.**
`KafkaAdmin` 도 없어서 `KafkaTopicConfig` 가 죽은 코드였고(토픽은 브로커 auto-create 로 생겼다,
DLT 는 아예 없었다), `KafkaConfig` 에 `KafkaAdmin` 빈을 직접 만들어 살렸다.

**PowerShell 에서 컨테이너 로그를 한글로 검색하면 안 잡힌다.** `docker compose logs` 의
UTF-8 출력을 콘솔이 CP949 로 읽어 `諛쒓툒 湲곕줉...` 처럼 깨지므로,
`Select-String '재고 보상'` 이 **빈 결과**를 낸다. 로그가 없는 것이 아니라 화면이 깨진 것인데,
**정상 동작을 실패로 읽게 되는 자리다** (실제로 한 번 그럴 뻔했다).

```powershell
docker compose logs coupon-service | Select-String 'IssuanceCompensator'   # ASCII 로 찾는다
[Console]::OutputEncoding=[Text.Encoding]::UTF8                            # 또는 인코딩을 맞춘다 (그 세션 한정)
```

**새로 만드는 `.ps1` 에는 UTF-8 BOM 을 붙인다.** PowerShell 5.1 은 BOM 이 없으면 파일을
시스템 코드페이지(한국어 Windows 면 CP949)로 읽어 한글 주석이 깨지고, 운이 나쁘면
따옴표가 어긋나 **파싱 에러**가 난다. 기존 스크립트가 전부 BOM 을 달고 있는 이유다.

**부하가 끝난 직후에 `count_match` 를 재면 안 된다.** `issued_quantity` 는 1초 주기로
따라오는 파생 값이라 아직 못 따라온 값을 보고 FAIL 이 뜬다. `load-test.ps1` 이
검증 전에 3초 기다리는 이유다. 결함이 아니라 측정 시점 문제다.

**mac 판 스크립트와 `scripts/concurrency/api.sh` 는 `/api/coupons` 를 호출한다.**
실제 컨트롤러 경로는 `/api/v1/coupons` 라 그대로 돌리면 전부 404 다. Windows 판에만 반영되어 있다.

**k6 컨테이너에는 `./scripts` 를 통째로 마운트한다.** 트랙별 하위 디렉터리를 각각 마운트하면
디렉터리를 옮길 때마다 조용히 깨진다 — 실제로 한 번 깨졌다. 없는 호스트 경로를 마운트하면
Docker 가 **빈 디렉터리를 만들어 주기 때문에** 에러가 아니라 "스크립트가 없다" 로 나타난다.

**Windows 에서 호스트 → 앱 호출은 `localhost` 가 아니라 `127.0.0.1` 을 쓴다.**
`localhost` 가 IPv6 `::1` 로 먼저 해석되는데 Docker Desktop 의 그 경로가 응답 없이 멈추는 경우가 있어,
연결이 실패가 아니라 타임아웃으로 끝난다 (IPv4 로 폴백도 못 한다).

---

## 8. 현재 병목

병목은 세 번 옮겨 다녔고, 마지막에는 **응답 경로 밖으로** 나갔다.

| 단계 | 병목 | 상한 |
|---|---|---:|
| naive / pessimistic / lua / lua-gate | `coupon` 단일 행 UPDATE 의 직렬화 | ~290건/초 |
| lua-wb | Hikari 커넥션 풀 기본값 10개 | ~2,700건/초 |
| lua-pool | **미확정.** Tomcat 스레드 200개가 용의자였다 | ~4,000건/초 |
| queue-mem / queue-async | **응답 경로에는 없다.** 부하 상한에 먼저 걸린다 | 5,000건/초 (부하 상한) |
| " | 대신 **워커의 DB 쓰기** 가 새 병목이다 | ~155/틱 |
| kafka / kafka-restore | 응답 경로는 그대로 부하 상한 | 5,000건/초 (부하 상한) |
| " | **소비자를 3배로 늘려도 쓰기는 그대로다** | ~157/틱 |
| **kafka-nocount (현재)** | 그 쓰기를 잡던 것은 **`coupon` 단일 행 UPDATE** 였다 | **≥160/s, 상한 미상** |
| " | **하네스가 못 잰다.** 드레인이 부하 구간 안에서 끝난다 | 측정 불가 |

행 락을 없애자 커넥션 수가, 커넥션을 늘리자 그 다음이 드러났고,
쓰기를 큐 뒤로 밀자 응답 경로에서는 아예 사라졌다.
그리고 그 큐 뒤에 다시 나타난 것도 **같은 단일 행 UPDATE** 였다.
근거와 계산은 [`load-test-k6.md` §12.4, §12.7, §13, §14, §16](load-test-k6.md).

**`queue-mem` 에서 부하가 처음으로 100% 전달됐다.** `dropped_iterations` 0,
`vus_max` 가 상한(5,000)에 붙지 않음, `status 0` 0건. 그래서 §9 의 신뢰 조건을 여유 있게
만족하고, 연결 거부가 열린 모델 탓이라던 진단도 뒤집혔다 — 앱이 못 따라간 결과였다.

**쓰기 병목 질문은 닫혔다.** 소비자 수가 아니고(`kafka`, 3배로 늘려도 155 → 157),
커밋당 fsync 도 아니다 — `coupon` 단일 행 UPDATE 한 줄을 빼자 드레인이 통째로 사라졌다
(`kafka-nocount`, [`load-test-k6.md` §16.4](load-test-k6.md)).

**쓰기 처리량 비교는 여기서 닫았다.** 하네스(드레인 폴링)는 "부하가 끝난 뒤에도 계속 쓰는"
구현을 재려고 만든 것인데 `kafka-nocount` 는 부하 구간 안에서 다 끝내므로 표본이 안 잡힌다.
**"≥160/s, 상한 미상" 이 닫는 시점의 상태이고, 이건 결함이 아니라 자의 눈금이 여기까지라는 뜻이다.**
다시 열 일이 생기면 `written_at` 계측 컬럼을 하네스가 추가하는 방식으로 간다
([`load-test-k6.md` §16.6](load-test-k6.md)).

지금 답이 없는 질문 둘.
- **응답 p99 가 6.45 → 11.74ms 로 밀린 이유를 아직 안 갈랐다.** 쓰기가 부하 구간 안으로
  들어와 요청 경로와 자원을 다투는 것까지는 분명한데, 무엇을 다투는지(Hikari 풀? CPU?)는 모른다.
  위 하네스를 고친 뒤에야 잴 수 있다
- **응답 p99 가 앱의 상한인가?** 모른다. 부하 상한(5,000rps)에 먼저 걸렸다.
  더 세게 걸면 알 수 있지만 그러면 12절까지의 기록과 비교가 깨진다
