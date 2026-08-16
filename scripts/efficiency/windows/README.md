# 효율 측정 — 캐시 stampede / 매진 시그널 (Windows)

`scripts/efficiency/` 의 mac 용 스크립트(bash + 로컬 k6)를 Windows 환경으로 옮긴 것.
**원본은 건드리지 않았다.** 두 판본은 부하 조건(rate, VU, duration)이 같아야 결과를 비교할 수 있다.

`concurrency` 가 **정확성**, `response` 가 **응답시간 분포**를 재는 데 비해
여기는 **같은 결과를 내는 데 드는 비용**을 잰다 — DB 조회 횟수, 매진 후 헛도는 요청 수.

| 시나리오 | k6 | 무엇을 보나 |
|---|---|---|
| ① policy | `coupon_burst.js` | 발급 API 의 쿠폰 정보 조회 급증. 500 req/s × 30s |
| ② sellout | `post_sellout_refresh.js` | 매진 후 새로고침 폭주. 4,000 req/s × 30s |

## 시작하기 전에 — 새 이미지가 필요하다

```powershell
.\build-and-run.ps1 -Tag cache-4-0
```

`CacheMetricsController` 와 `coupon.cache.*` 설정은 이 트랙에서 처음 들어온 것이라
**예전 태그의 이미지에는 `/metrics/cache` 가 없다.** 그 상태로 돌리면 `run.ps1` 이
측정 시작 전에 멈추고 이 커맨드를 안내한다 (DB/Redis 는 건드리기 전이다).

- 단계별로 태그를 나눈다. 지금까지: `cache-4-0`(캐시 없음) → `rediscache-4-1`(Redis read-through)
  → `single-flight-4.2`(락으로 stampede 차단) → SWR → L1 캐시(시나리오 ②).
  요약 JSON 이름에 태그가 붙으므로 `coupon_burst-single-flight-4.2-steady.json` 처럼 남는다.
- **예전 태그로 되돌아갈 때는 `-NoBuild` 필수.** 안 붙이면 현재 소스를 빌드해 예전 이름표를
  붙이므로 진짜 예전 이미지가 사라진다 (CLAUDE.md).
- `build-and-run.ps1` 은 쿼리 로그가 **켜진** 채로 띄운다. 이어서 `run.ps1` 이
  `docker-compose.loadtest.yml` 을 얹어 컨테이너를 한 번 재생성하며 로그를 끈다.
  라운드 밖에서 일어나므로 워밍업에는 영향이 없다.

## 실행 (프로젝트 루트에서)

```powershell
.\scripts\efficiency\windows\run.ps1                        # 두 시나리오, 각각 워밍업 1회 + 본 측정 1회
.\scripts\efficiency\windows\run.ps1 -Scenario policy        # ① 만
.\scripts\efficiency\windows\run.ps1 -Scenario sellout       # ② 만
.\scripts\efficiency\windows\run.ps1 -Scenario policy -Once  # 한 회차만 (스크립트 손볼 때. 비교에는 쓰지 않는다)
```

한 라운드 = **리셋 → 쿠폰 생성 → [매진] → 카운터 리셋 → k6 → 카운터 읽기**.
요약 JSON 은 `build\k6\<시나리오>-<이미지태그>-<회차>.json` 에 남는다.

1회차는 **버리는 워밍업**이다 (JVM JIT, Hikari 풀, Lettuce 커넥션이 데워지는 비용).
그래서 **라운드 사이에 서비스 컨테이너를 재생성하면 안 된다.** 컨테이너를 만드는 일(쿼리 로그 설정)은
라운드 밖에서 한 번만 하고, k6 실행에는 `--no-deps` 를 준다.

## 결과를 믿기 전에 확인할 것

### 1. checks 세 항목이 모두 100% 인가

| check | 100% 가 아니면 |
|---|---|
| `route exists (not 404)` | 경로나 `BASE_URL` 이 틀렸다. **결과 전체가 무의미하다** |
| `connected (not status 0)` | TCP 단에서 튕겼다 (아래 2번) |
| `no server error (not 5xx)` | 앱이 터지고 있다. 측정이 아니라 버그다 |

> mac 원본 `scripts/efficiency/*.js` 와 `create_*.sh` 는 `/api/coupons` 를 호출하는데
> 실제 컨트롤러 경로는 `/api/v1/coupons` 다. Windows 판본에만 반영되어 있다.

**5xx 검사는 나중에 추가됐다.** single-flight 를 붙일 때 Lua 파일명이 한 글자 틀려
전 요청이 500 이었는데, 404·status 0 검사만 있던 탓에 **`checks 100%` 로 통과했다.**
그때 그것을 잡아낸 것은 checks 가 아니라 아래 **"읽어야 할 카운터"** 의 합 불변식이었다.

### 2. `status_conn_error` 를 같이 읽는다

`status 0` 은 앱이 응답한 게 아니라 **TCP 단에서 튕긴 것**이고, `duration ≈ 0ms` 로 기록돼
분포를 좋아 보이게 만든다. 그래서 이식본은 **`status 0` 을 지연 Trend 에서 빼고**
`status_conn_error` 로 따로 센다 (`response` 트랙과 같은 처리, CLAUDE.md 규칙).

즉 여기서 나오는 p99 는 **"앱이 실제로 응답한 요청의 p99"** 다. 특히 시나리오 ②는 4,000 rps 라
response 트랙(5,000 rps 에서 요청의 15~27%)과 같은 조건이다. 이 값이 크면
**"빨라진 것" 과 "튕긴 것" 이 섞여 있다는 뜻**이므로 fast-path 효과를 그만큼 깎아서 읽어야 한다.

### 3. threshold 는 자동 판정하지 않는다

`p(99)<200` / `p(99)<100` 은 캐시·시그널 도입 이후를 기대한 값이라 초기 단계에서는 깨지는 것이 정상이다.
k6 은 깨지면 **exit 99** 를 내고 `run.ps1` 이 그걸 허용 코드로 둔다.

**그런데 k6 의 종료 코드가 틀린 적이 있다** (`scripts\response\windows\README.md` 3번 —
max 46.59ms 인 실행이 `p(99)<500` 을 넘겼다고 exit 99 를 냈다). 그래서 이 트랙은 종료 코드로
판정하지 않고 요약 JSON 과 화면 수치를 눈으로 본다.

```powershell
(Get-Content -Raw build\k6\coupon_burst-<태그>-steady.json | ConvertFrom-Json).metrics.issue_policy_latency
(Get-Content -Raw build\k6\post_sellout_refresh-<태그>-steady.json | ConvertFrom-Json).metrics.issue_latency
```

### 4. 상태 코드 분포

두 시나리오 모두 **409 가 정상 응답**이다. `NotStartedException`, `SoldOutException` 이
전부 HTTP 409 이기 때문이다 (`support/DomainException.kt`).

| 시나리오 | 기대 | 비정상 |
|---|---|---|
| ① policy | `status_409_not_started` ≈ 요청 수 | `status_2xx` 가 0 이 아니면 startsAt 이 안 먹은 것 |
| ② sellout | `status_409_sold_out_or_dup` ≈ 요청 수 | `status_2xx` 가 0 이 아니면 매진이 안 된 것 |

`status_other`(5xx 등)가 크면 그 라운드는 버린다.

## 읽어야 할 카운터 — `/metrics/cache`

`run.ps1` 이 각 라운드 끝에 찍는다. k6 직전에 리셋되므로 **k6 구간만의 값**이다.
(시나리오 ②는 매진시킨 **뒤에** 리셋한다 — 순서가 바뀌면 sell-out 이 만든 100 건이 섞인다.)

| 카운터 | 시나리오 | 보는 법 |
|---|---|---|
| `couponDbReads` | ① | 낮을수록 좋다. 캐시가 흡수한 만큼 줄어든다 |
| `couponCacheHits` | ① | `couponDbReads` 와 합이 요청 수에 가까워야 한다 |
| `soldOutRedisExists` | ② | 매진 판정을 위해 Redis 까지 간 횟수 |
| `soldOutFastPathHits` | ② | 컨트롤러 진입 직후 잘린 횟수. 시그널 적용 후 요청 수에 수렴해야 한다 |

**`couponDbReads + couponCacheHits` 는 요청 수와 정확히 맞아야 한다.** 모자라면 어딘가에서
요청이 캐시 경로를 안 타고 새는 것이다. 카운터를 올리는 곳은 `CouponCacheRepository.getOrLoad`
한 군데다 (미스면 `couponDbReads`, 히트면 `couponCacheHits`).

**이 트랙에서 가장 먼저 보는 줄이다.** single-flight 를 붙일 때 둘 다 `0` 인데
`checks 100%` 로 통과한 실행이 있었다 — Lua 파일명이 틀려 카운터를 올리기 **전에** 예외가
났기 때문이다. 합이 0 이거나 요청 수와 크게 다르면 나머지 숫자는 읽지 않는다.

시나리오 ① (500/s × 30s = 15,000, TTL 1000 / latency 100 기준):

| 태그 | `couponDbReads` | avg | p(99) | 뜻 |
|---|---:|---:|---:|---|
| `cache-4-0` | 15,001 | 272.68ms | 747.91ms | 캐시 없음. **Hikari 풀(50) 포화**라 대기가 붙는다 |
| `rediscache-4-1` | 1,250 | 9.45ms | 102.37ms | 캐시는 먹었다. 남은 건 거의 전부 **stampede** |
| `single-flight-4.2` | **27** | 6.88ms | 103.11ms | **이론적 바닥**(사이클당 1건). p99 는 안 움직인다 |

산수와 해석은 `docs/load-test-k6.md` §19. **판정은 p99 가 아니라 이 카운터로 한다** —
single-flight(4-1b)를 넣어도 대기하는 요청 때문에 p99 는 여전히 튄다.

## 측정 조건 — 결과를 비교하기 전에 이것부터 맞춘다

이 두 값이 이 트랙 수치의 의미를 통째로 바꾼다. `docker-compose.yml` 이 기본값을 주고,
셸에서 같은 이름의 환경변수로 덮을 수 있다. **하네스는 강제하지 않는다** — 대신
`run.ps1` 이 시작할 때 컨테이너에 실제로 적용된 값을 두 줄로 찍는다.

| 환경변수 | compose 기본값 | 뜻 |
|---|---|---|
| `COUPON_CACHE_TTL_MS` | `1000` | 캐시 만료. 짧을수록 stampede 윈도우가 자주 온다 |
| `COUPON_CACHE_SIMULATED_LOAD_LATENCY_MS` | `100` | DB 조회에 심는 인위적 지연 (`CouponIssuePolicyReader` 의 `Thread.sleep`). `0` 이면 조회가 1ms 라 캐시 효과가 p99 에 아예 안 드러난다 |

```powershell
$env:COUPON_CACHE_TTL_MS = '10000'      # 덮어쓰려면. compose 가 .env 대신 셸 환경변수를 본다
```

**둘 중 하나라도 다르면 기존 측정 기록과 비교가 성립하지 않는다.** 실제로 4-0 은 `10000/0`,
4-1 은 `1000/100` 에서 쟀고, 그 탓에 p99 가 1.45ms → 102ms 로 "나빠진" 것처럼 보였다
(회귀가 아니라 워크로드가 바뀐 것이다 — `docs/load-test-k6.md` §18·§19).
그래서 **결과를 읽기 전에 로그 맨 위의 두 줄을 먼저 본다.**
바꿔야 한다면 그 사실을 문서에 명시하고 전 구현을 다시 잰다 (CLAUDE.md).

## 구현 전환

구현은 브랜치가 아니라 **이미지 태그**로 나눈다. 요약 JSON 파일명에 태그가 붙으므로
단계별 결과가 서로 덮어쓰지 않는다.

```powershell
.\build-and-run.ps1 -Tag swr-4.3        # 다음 단계를 빌드해서 띄운다 (태그 이름은 자유)
.\scripts\efficiency\windows\run.ps1
#   → build\k6\coupon_burst-swr-4.3-steady.json
#   → build\k6\post_sellout_refresh-swr-4.3-steady.json

.\build-and-run.ps1 -Tag cache-4-0 -NoBuild   # 기준선으로 되돌아가 다시 잴 때 (-NoBuild 필수)
```

## 단계를 나눠 돌리려면

```powershell
.\scripts\efficiency\windows\reset.ps1
$couponId = .\scripts\efficiency\windows\create-small-coupon.ps1
.\scripts\efficiency\windows\sell-out.ps1 -CouponId $couponId
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/metrics/cache/reset
docker compose run --rm --no-deps -e COUPON_ID=$couponId k6 run /scripts/efficiency/windows/k6/post_sellout_refresh.js
Invoke-RestMethod -Uri http://127.0.0.1:8080/metrics/cache
```

단, 이렇게 돌리면 쿼리 로그가 켜진 채일 수 있다. p99 를 읽을 거라면
`docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d coupon-service` 를
먼저 하고 `docker inspect` 로 `SPRING_JPA_SHOW_SQL=false` 를 확인한다.
`run.ps1` 은 이걸 매번 자동으로 하고, 안 되어 있으면 측정하지 않고 멈춘다.
