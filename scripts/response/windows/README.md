# 응답시간 측정 (Windows)

`scripts/response/` 의 mac 용 스크립트(bash + 로컬 k6)를 Windows 환경으로 옮긴 것.
**원본은 건드리지 않았다.** 두 판본은 부하 조건(rate, VU, USER_POOL)이 같아야 결과를 비교할 수 있다.

`scripts/concurrency/` 트랙이 **정확성**(과발급·중복발급)을 재는 반면
여기는 **응답 시간 분포(P99)** 를 잰다. 동기 구현 → 큐 디커플링 비교의 기준 시나리오다.

## 실행 (프로젝트 루트에서)

```powershell
.\scripts\response\windows\run.ps1          # 워밍업 1회 + 본 측정 1회
.\scripts\response\windows\run.ps1 -Once    # 한 회차만 (스크립트 손볼 때. 비교에는 쓰지 않는다)
```

한 라운드 = **리셋 → 쿠폰 생성 → k6(issue_burst) → 검증**.
요약 JSON 은 `build\k6\issue_burst-<이미지태그>-<회차>.json` 에 남는다.

### 왜 라운드가 두 번인가

1회차는 **버리는 워밍업**이다. JVM JIT, Hikari 풀, Lettuce 커넥션이 데워지는 비용이
1회차 응답시간에 그대로 섞이기 때문이다. 2회차가 steady-state 측정값이다.

그래서 **라운드 사이에 서비스 컨테이너를 재생성하면 안 된다.** 컨테이너를 만드는 일
(쿼리 로그 설정 적용)은 라운드 밖에서 한 번만 하고, k6 실행에는 `--no-deps` 를 준다
(k6 서비스의 `depends_on: coupon-service` 때문에 compose 가 앱을 건드릴 여지가 있다).
`run.ps1` 이 끝날 때 컨테이너 ID 를 대조해 재생성 여부를 알려준다.

## 결과를 믿기 전에 확인할 것

### 1. `route exists (not 404)` 가 100% 인가

100% 가 아니면 경로나 `BASE_URL` 이 틀린 것이고 **결과 전체가 무의미하다.**
요청이 전부 404 로 떨어져도 k6 은 정상 종료하고 검증은 발급 0건을 보고 PASS 를 낸다.

> mac 원본 `scripts/response/issue_burst.js` 는 `/api/coupons` 를 호출하는데
> 실제 컨트롤러 경로는 `/api/v1/coupons` 다. Windows 판본에만 반영되어 있다.

### 2. `connected (not status 0)` 와 `status_conn_error`

`status 0` 은 앱이 응답한 게 아니라 **TCP 단에서 튕긴 것**이다. 이 트랙에서는 이게
p99 를 직접 오염시킨다 — 연결 거부는 `duration ≈ 0ms` 로 기록돼 분포를 좋아 보이게 만든다.

그래서 `issue_burst.js` 는 **`status 0` 을 `issue_latency` 에 넣지 않고** `status_conn_error`
로 따로 센다. 즉 여기서 나오는 p99 는 **"앱이 실제로 응답한 요청의 p99"** 다.
`status_conn_error` 가 크면 그만큼 살아남은 요청만 본 수치라는 뜻이므로 같이 읽어야 한다.

현재 부하 조건(열린 모델 5,000rps)에서는 요청의 **15~27% 가 여기 해당한다**
(`docs/load-test-k6.md` §12.7.3). 부하 모델을 닫힌 모델로 바꾸면 사라지는 문제지만,
그러면 기존 측정 기록과 비교가 성립하지 않으므로 아직 바꾸지 않았다 (`docs/load-test-k6.md` §11).

### 3. `issue_latency` threshold 는 깨지는 것이 정상이다

`p(99)<500` 은 큐 디커플링 이후를 기대한 값이다. 동기 구현에서 깨지는 것이 출발점이고,
k6 은 이때 **exit 99** 를 낸다. `run.ps1` 이 99 를 허용 코드로 두고 검증까지 진행한다.

### 4. 검증 출력

`verify-burst.ps1` 은 쓰기가 멈출 때까지 폴링으로 기다린 뒤 판정한다.

| 항목 | 뜻 |
|---|---|
| `over_issuance` | `issuance_rows > total_quantity` → **FAIL**. 전역 N장 보장이 깨짐 |
| `count_match` | `issued_quantity = issuance_rows`. 어긋나면 **WARN** (파생 카운터라 늦을 수 있다) |
| Redis 잔여 재고 | `total_quantity - issuance_rows` 와 맞아야 한다. 다르면 **재고 누수** |

Redis 확인이 붙어 있는 이유: 위 두 판정은 DB 안에서만 계산되므로 Redis 와 DB 사이에서
새는 과소발급을 잡지 못한다. 실제로 재고 23장이 사라졌는데 PASS 가 나온 적이 있다
(`docs/load-test-k6.md` §12.2).

## 구현 전환

구현은 브랜치가 아니라 **이미지 태그**로 나눈다. 요약 JSON 파일명에 태그가 붙으므로
구현별 결과가 서로 덮어쓰지 않는다.

```powershell
.\build-and-run.ps1 -Tag lua-pool
.\scripts\response\windows\run.ps1
#   → build\k6\issue_burst-lua-pool-warmup.json
#   → build\k6\issue_burst-lua-pool-steady.json
```

## 단계를 나눠 돌리려면

```powershell
.\scripts\response\windows\reset.ps1
$couponId = .\scripts\response\windows\create-coupon.ps1
docker compose run --rm --no-deps -e COUPON_ID=$couponId k6 run /scripts/response/windows/k6/issue_burst.js
.\scripts\response\windows\verify-burst.ps1 -CouponId $couponId
```

단, 이렇게 돌리면 쿼리 로그가 켜진 채일 수 있다. 응답시간을 읽을 거라면
`docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d coupon-service` 를
먼저 하고 `docker inspect` 로 `SPRING_JPA_SHOW_SQL=false` 를 확인한다.
`run.ps1` 은 이걸 매번 자동으로 하고, 안 되어 있으면 측정하지 않고 멈춘다.
