# 구조 안내

이 저장소가 어떻게 조립되어 있는지 한 번에 파악하기 위한 문서.
코드를 처음부터 읽지 않아도 어디에 무엇이 있고 왜 그렇게 되어 있는지 알 수 있게 하는 것이 목적이다.

측정 결과와 그 해석은 [`load-test-k6.md`](load-test-k6.md), 도메인 정의는
[`domain-model.md`](domain-model.md), 테이블 정의는 [`db-schema.md`](db-schema.md) 에 있다.
여기서는 그 숫자들을 다시 적지 않고 가리키기만 한다.

기준 시점: 2026-08-14, `coupon-service:lua-wb` 측정 직후.

---

## 1. 이 프로젝트의 성격

선착순 쿠폰 발급에서 생기는 **동시성 결함을 일부러 재현하고, 구현을 바꿔가며 측정·비교하는 학습 프로젝트**다.
프로덕션 코드가 아니다. 그래서 몇 가지가 의도적으로 "덜 되어" 있다.

- 인증이 없다. 사용자는 `X-User-Id` 헤더로 그냥 받는다
- `ddl-auto: update` 로 스키마를 만든다
- `application.yaml` 이 쿼리 로그를 켜 두고 있다 (개발 중 SQL 을 보려고)

**구현 전환은 브랜치가 아니라 이미지 태그로 한다.** `naive`, `pessimistic`, `lua`,
`lua-fix`, `lua-gate`, `lua-wb`, `lua-pool` 을 같은 소스 트리에서 번갈아 빌드해 태그만 다르게 붙인다
(각각이 무엇인지는 §5). 브랜치로 나누면 스크립트·문서를 고칠 때마다 여러 곳에 포팅해야 하고,
서로 다른 하네스로 잰 수치는 비교가 성립하지 않기 때문이다.

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
  └─ CouponService.issue                    트랜잭션 없음
       ├─ couponIssuer.tryIssue             Redis Lua — 발급 자격 판정 전체가 여기서 원자적으로 끝난다
       │                                      SOLD_OUT / DUPLICATE 는 여기서 끝. DB 커넥션을 잡지 않는다
       └─ issuanceWriter.write              @Transactional — 통과한 요청만
            ├─ couponRepository.findById      SELECT coupon (만료일 계산용)
            ├─ coupon.isBookingOpen(now)      시작 전이면 NOT_STARTED
            └─ issuanceRepository.save        INSERT issuance
       ⤷ write 가 실패하면 couponIssuer.restore 로 Redis 재고를 되돌린다
```

**판정은 Redis, 기록은 DB** 로 나뉘어 있는 것이 이 구조의 핵심이다.
경합이 몰리는 자리(재고 차감, 1인 1매)는 전부 Redis 의 Lua 스크립트 안에 있고,
DB 는 서로 다른 행에 INSERT 만 하므로 요청끼리 직렬화되지 않는다.

`coupon.issued_quantity` 는 발급 요청이 올리지 않는다. `IssuedQuantitySynchronizer` 가
1초마다 `total_quantity − (Redis 재고)` 로 덮어쓰는 파생 값이다 (write-behind).
요청마다 그 열을 올리던 시절에는 모든 요청이 그 한 행의 UPDATE 에서 줄을 서서
처리량이 초당 290건에 묶여 있었다 ([`load-test-k6.md` §12.4](load-test-k6.md)).

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
    CouponService.kt            발급 흐름. 게이트 통과 → 쓰기 → 실패 시 보상
    CouponIssuer.kt             Redis Lua 호출 래퍼. tryIssue / restore / initStock
    IssuanceWriter.kt           게이트를 통과한 요청의 DB 쓰기 (@Transactional 경계)
    IssuedQuantitySynchronizer.kt  issued_quantity 를 Redis 에서 파생시켜 1초마다 반영
    IssuanceService.kt          사용/조회
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
| `coupon:{id}:issued` | Set (userId) | `issue.lua` 가 발급 성공 시 `SADD` |

**재고의 진실은 DB 가 아니라 Redis 에 있다.** `resources/lua/issue.lua` 한 스크립트가
중복 여부와 재고를 함께 판정하고 그 자리에서 차감한다.

Redis 는 싱글 스레드라 **명령 하나는 그 자체로 원자적**이다. 그래서 `DECR` 만 쓸 거면 Lua 가 필요 없다.
문제는 판정이 명령 하나로 안 끝난다는 것이다 — `SISMEMBER` → `GET` → `DECR` → `SADD` 네 단계이고,
그 사이 왕복마다 다른 요청이 끼어들면 같은 사람에게 두 장이 나가거나 재고가 음수가 된다.
Lua 스크립트는 이 여러 명령을 **Redis 서버 안에서 한 덩어리로** 실행해 그 틈을 없앤다.
**Lua 를 쓰는 이유는 속도가 아니라 이 원자성이다.**

Redis 는 DB 트랜잭션 밖이므로 차감 뒤 DB 쓰기가 실패해도 저절로 돌아오지 않는다.
`CouponService.issue` 가 실패를 잡아 `CouponIssuer.restore` 로 되돌린다.
이 보상이 없으면 그 한 장은 아무에게도 가지 않은 채 사라진다 —
실제로 `lua` 태그에서 1,000명 시나리오 한 번에 23장이 샜고,
**DB 만 보는 `verify.ps1` 은 그것을 OK 로 통과시켰다** ([`load-test-k6.md` §12.2](load-test-k6.md)).

---

## 5. 세 구현의 차이

같은 소스 트리에서 `CouponService.issue` 주변만 바꿔가며 만든다.

| 태그 | 재고 판정 | `issued_quantity` | 정확성 | 처리량 |
|---|---|---|---|---:|
| `naive` | `isSoldOut()` 만 | 요청마다 `++` (dirty checking) | FAIL — 과발급, 카운터 90% 유실 | ~290/s |
| `pessimistic` | `SELECT … FOR UPDATE` 후 검사 | 락 안에서 증가 | OK | ~263/s |
| `lua` | Redis Lua 원자 차감 (DB 검사 뒤) | 요청마다 원자 UPDATE | OK (단, 재고 누수 있음) | ~285/s |
| `lua-fix` | 위와 같음 + 롤백 시 재고 복구 | 위와 같음 | OK | ~278/s |
| `lua-gate` | Lua 게이트를 DB 접근 **앞으로** | 요청마다 원자 UPDATE | OK | ~252/s |
| `lua-wb` | Lua 게이트가 맨 앞 | write-behind (1초 주기) | OK | ~2,700/s |
| **`lua-pool` (현재)** | 위와 같음 | 위와 같음 | OK | **~4,000/s** |

`pessimistic` 버전의 리포지토리 메서드는 `domain/CouponRepository.kt` 에 주석으로 보존되어 있고,
`incrementIssueQuantity` 도 되돌려 비교할 수 있게 남겨 두었다.

**이 표에서 읽어야 할 것**: `lua` → `lua-gate` 까지 처리량이 전혀 안 움직였다.
Redis 를 붙여 놓고도 `coupon` 단일 행 UPDATE 를 요청 경로에 남겨 두었기 때문이다.
그 UPDATE 를 빼자(`lua-wb`) 10배가 됐다. **경합 지점을 DB 밖으로 빼는 것이 Lua 의 값어치인데,
DB 쪽 경합을 같이 없애지 않으면 복잡도만 늘고 이득이 없다.**

`lua-pool` 은 코드 변경이 아니라 `application.yaml` 의 Hikari 풀 크기를 10 → 50 으로 올린 것이다.
행 락이 사라지자 다음 병목이 커넥션 수로 드러났다.
자세한 분석은 [`load-test-k6.md` §12](load-test-k6.md).

---

## 6. 부하 테스트 하네스

Windows 판은 `scripts/windows/`, mac 원본은 `scripts/load/` 다.
**mac 판은 수정하지 않는다.** 두 판본의 부하 조건(rate, VU, USER_POOL)이 같아야 결과를 비교할 수 있다.

### 역할 분담

| 스크립트 | 하는 일 |
|---|---|
| `build-and-run.ps1` | jib 로 이미지 빌드 → `docker load` → 태그를 `.env` 에 기록 → compose 기동 |
| `scripts/windows/load-test.ps1` | 쿼리 로그 끄기 → 리셋 → 쿠폰 생성 → k6 → 카운터 동기화 대기 → 검증 |
| `scripts/windows/reset.ps1` | `coupon` / `issuance` TRUNCATE + Redis `FLUSHALL` |
| `scripts/windows/create-coupon.ps1` | 쿠폰 1개 생성하고 ID 를 표준출력으로 반환 |
| `scripts/windows/verify.ps1` | 판정 SQL 실행 → 과발급/카운터 일치 여부 출력 |
| `scripts/windows/k6/*.js` | k6 시나리오. `constant-arrival-rate` 5,000/s × 30s |

### compose 구성 (`docker-compose.yml`)

- `mysql` 8.4, `redis` 8.0 (AOF 켜짐), `coupon-service`, `k6`
- `coupon-service` 의 이미지 태그는 `${COUPON_IMAGE_TAG:-latest}` — `.env` 에서 온다
- `k6` 는 `profiles: ["load"]` 라 평소 `up -d` 에는 뜨지 않고,
  `docker compose run --rm k6 …` 로 명시 실행할 때만 뜬다.
  앱과 같은 네트워크 안이라 `http://coupon-service:8080` 으로 직접 붙는다
  (Windows 의 localhost 포트포워딩을 안 거친다)
- `docker-compose.loadtest.yml` 은 측정 시 쿼리 로그를 끄는 override

### 검증 기준 (`verify.ps1`)

| 컬럼 | 뜻 |
|---|---|
| `over_issuance` | `issuance_rows > total_quantity` → FAIL. 전역 N장 보장이 깨짐 |
| `count_match` | `issued_quantity = issuance_rows` → OK. **Redis 가 센 수와 DB 에 들어간 수의 교차 검증** |
| `duplicate_users` | 같은 사용자가 2장 이상 받은 수 (UNIQUE 때문에 항상 0) |

**이 검증만으로는 부족하다.** 세 컬럼 모두 DB 안에서만 계산되므로,
Redis 재고가 새는 과소발급을 잡지 못한다 (실제로 놓친 적이 있다 — §12.2).
발급 후 `docker compose exec redis redis-cli GET coupon:1:stock` 이
`total_quantity − 발급 수` 와 맞는지 같이 보는 것이 좋다.

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
다시 시작하므로, 비우지 않으면 이전 실행이 남긴 `coupon:1:issued` 집합을 그대로 물려받아
두 번째 실행부터 모든 요청이 "이미 발급" 으로 튕긴다(발급 0건). 재고 키만 쓰던 시절에는
`initStock` 이 덮어써 줘서 이 문제가 드러나지 않았다.

**부하가 끝난 직후에 `count_match` 를 재면 안 된다.** `issued_quantity` 는 1초 주기로
따라오는 파생 값이라 아직 못 따라온 값을 보고 FAIL 이 뜬다. `load-test.ps1` 이
검증 전에 3초 기다리는 이유다. 결함이 아니라 측정 시점 문제다.

**mac 판 스크립트(`scripts/load/`)와 `scripts/api.sh` 는 `/api/coupons` 를 호출한다.**
실제 컨트롤러 경로는 `/api/v1/coupons` 라 그대로 돌리면 전부 404 다. Windows 판에만 반영되어 있다.

**Windows 에서 호스트 → 앱 호출은 `localhost` 가 아니라 `127.0.0.1` 을 쓴다.**
`localhost` 가 IPv6 `::1` 로 먼저 해석되는데 Docker Desktop 의 그 경로가 응답 없이 멈추는 경우가 있어,
연결이 실패가 아니라 타임아웃으로 끝난다 (IPv4 로 폴백도 못 한다).

---

## 8. 현재 병목

병목은 두 번 옮겨 다녔다.

| 단계 | 병목 | 상한 |
|---|---|---:|
| naive / pessimistic / lua / lua-gate | `coupon` 단일 행 UPDATE 의 직렬화 | ~290건/초 |
| lua-wb | Hikari 커넥션 풀 기본값 10개 | ~2,700건/초 |
| **lua-pool (현재)** | **미확정.** Tomcat 스레드 200개가 다음 용의자 | **~4,000건/초** |

행 락을 없애자 커넥션 수가, 커넥션을 늘리자 그 다음이 드러났다.
근거와 계산은 [`load-test-k6.md` §12.4, §12.7](load-test-k6.md).

부하는 `constant-arrival-rate` 5,000/s 인 열린 모델이라 여전히 요청의 15% 안팎이
연결 수락 큐를 넘겨 TCP 단에서 튕긴다(`connection refused`). 다만 부하 전달률이
73% → 94% 로 올라오면서 `http_reqs` 와 `dropped_iterations` 를 조건부로 읽을 수 있게 됐다
(조건은 §9 참고). 구현 비교에는 계속 **"앱에 도달한 요청 수"** 를 쓴다.

Tomcat 스레드를 올리기 전에 **닫힌 모델(`shared-iterations`) 전환이 먼저다**
([§11](load-test-k6.md)). 열린 모델로 5,000rps 를 계속 던지는 한 앱을 아무리 빠르게 해도
accept 큐는 넘치고, 그러면 스레드를 올린 효과가 연결 거부에 묻힌다.
