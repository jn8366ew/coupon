# 가용성 측정 — Redis 대기실 (Windows)

`scripts/availability/` 의 mac 용 스크립트(bash + 로컬 k6)를 Windows 환경으로 옮긴 것.
**원본은 건드리지 않았다.** 두 판본은 부하 조건(rate, duration, 재고)이 같아야 결과를 비교할 수 있다.

앞의 네 트랙이 "발급이 정확한가 / 얼마나 빠른가 / 얼마나 싸게 하는가 / 두 저장소가 맞는가" 를 봤다면,
여기는 **감당 못 할 트래픽이 왔을 때 앱 앞에서 무엇을 하는가** 를 본다.
대기실은 발급 경로에 들어오는 인원 자체를 초당 N명으로 깎는다.

| 모드 | k6 | 무엇을 보나 |
|---|---|---|
| `baseline` | `issue_flood.js` | 대기실 없이 발급 API 에 직접 도달한 요청 수. 대조군 — **대기실 이전 태그에서만 잴 수 있다** |
| `single` | `waiting_room_flood.js` | 서버 1대에서 초당 몇 명이 통과했나 (Redis 입장권 수) |
| `scale` | `waiting_room_flood.js` | 서버 2대에서도 **전역** 통과 속도가 유지되나 |
| `journey` | `waiting_room_journey.js` | 진입 → 폴링 → 발급까지의 실제 여정. 폴링이 만드는 추가 요청량 |
| `verify` | (없음) | 숫자 대신 기능 정오만 PASS/FAIL (순번·멱등성·게이트) |
| `gateway` | `gateway_rate_limit.js` | 어뷰저 1명이 게이트웨이(8090)에서 컷되고 정상 사용자는 안 막히나 |

앞의 다섯 모드는 8080 의 `coupon-service` 에 **직접** 붙는다. `gateway` 만 8090 을 거친다 —
그래서 게이트웨이를 추가해도 기존 기준선이 안 깨진다.

> **`gateway` 는 부하 조건이 다르다.** 어뷰저 200/s + 정상 20/s × **10초**, 허용 오차 **20%**.
> 나머지 모드는 1,000/s × 20초, 오차 30% 다. 러너의 파라미터도 (`-AbuserRate`,
> `-GatewayDuration`, `-GatewayTolerancePercent`) 따로 두었다 — 한쪽을 만졌을 때 다른 쪽
> 조건이 조용히 바뀌지 않게 하려는 것이다. **두 조건의 숫자를 나란히 놓고 읽으면 안 된다.**

## 시작하기 전에 — 새 이미지가 필요하다

```powershell
.\build-and-run.ps1 -Tag waiting-room
```

`WaitingRoomController` / `RedisWaitingRoom` / Lua 3종은 이 트랙에서 처음 들어온 것이라
**예전 태그의 이미지에는 `/api/waiting-room` 이 없다.** 그 상태로 돌리면 `run.ps1` 이
측정 시작 전에 멈추고 이 커맨드를 안내한다 (DB/Redis 는 건드리기 전이다).

- **예전 태그로 되돌아갈 때는 `-NoBuild` 필수.** 안 붙이면 현재 소스를 빌드해 예전 이름표를
  붙이므로 진짜 예전 이미지가 사라진다 (CLAUDE.md).
- **빌드가 성공했는데 대기실이 없다고 나오면 뜬 이미지를 먼저 본다.** 강의 compose 가
  `coupon-service.image` 를 `coupon-service:latest` 로 덮은 적이 있는데, 그러면 `.env` 에
  어떤 태그를 써도 compose 는 `latest`(= 5일 전 `naive`)를 띄운다. 빌드는 멀쩡하고
  재는 대상만 예전 구현인 상태다. 지금은 `${COUPON_IMAGE_TAG:-latest}` 로 되돌려 두었다.
  `run.ps1` / `verify.ps1` 은 이 상황을 감지하면 `.env` 태그와 실제 뜬 이미지를 나란히 찍고
  `-NoBuild` 로 다시 띄우는 커맨드를 안내한다.

## 실행 (프로젝트 루트에서)

```powershell
.\scripts\availability\windows\run.ps1                 # 자동 감지 (대기실이 있으면 single)
.\scripts\availability\windows\run.ps1 baseline        # 대기실 없는 대조군
.\scripts\availability\windows\run.ps1 single          # 서버 1대
.\scripts\availability\windows\run.ps1 scale           # 서버 2대 (coupon-service-2 를 띄웠다 내린다)
.\scripts\availability\windows\run.ps1 journey         # 진입 -> 폴링 -> 발급
.\scripts\availability\windows\run.ps1 verify          # 기능 정오만 PASS/FAIL
.\scripts\availability\windows\run.ps1 gateway         # 어뷰저 컷 (gateway 를 띄웠다 내린다)
```

`gateway` 는 자동 감지(`auto`)에 들어가지 않는다. 명시해야 돈다.

한 라운드 = **사전 확인 → 리셋 → 쿠폰 생성 → k6 → 판정**.
요약 JSON 은 `build\k6\<시나리오>-<이미지태그>[-<모드>].json` 에 남는다.
이 트랙에는 워밍업 회차가 없다 (재는 것이 응답시간 분포가 아니라 통과 인원이다).

부하 조건은 **1,000 req/s × 20s, 재고 1,000,000, 통과 속도 100/s, 허용 오차 ±30%**.
다른 트랙(5,000/s × 30s, 재고 5,000)과 조건이 다르므로 **p99 를 나란히 놓고 비교하면 안 된다.**
재고를 100만으로 잡은 이유는 매진이 나면 재는 대상이 "대기실" 이 아니라 "매진 처리" 로 바뀌기 때문이다.

## 지표 읽는 법

### `single` / `scale`

```
  진입 요청(http_reqs) = 20001
  진입 실패            = 0
  Redis 입장권         = 2000건, 약 100건/s (20초)
  VU 최대치 2 — 두 인스턴스로 갈렸습니다

PASS: 서버 2대에서도 전역 통과 속도가 유지됩니다 (100건/s, 허용 70~130건/s)
```

- `single` 은 기준선을 세우는 것이고, 그 값이 `scale` 에서도 유지되는지가 이 트랙의 결론이다.
  둘을 나란히 놓고 본다 (같은 100건/s 가 나와야 한다).
- **`scale` 의 PASS 는 `VU 최대치` 가 2 이상일 때만 2대 판정으로 읽는다.**
  k6 시나리오가 `BASES[__VU % BASES.length]` 로 **VU 단위** 라운드로빈을 하므로,
  부하가 가벼워 VU 를 1개만 쓰면 전 요청이 한 대로만 간다. 그래도 통과 속도는 100/s 라
  PASS 가 찍힌다 — 구현이 맞아서가 아니라 측정이 2대를 안 건드린 것이다.
  러너가 VU 최대치를 같이 찍고, 2 미만이면 노란 경고를 붙인다.
- 판정은 **k6 이 아니라 Redis** 다. 통과한 사람 수 = 살아 있는 입장권 키(`waiting:{id}:pass<userId>`) 수.
  k6 이 보는 것은 "줄을 섰다" 까지이고, 실제로 몇 명이 나갔는지는 드레인만 안다.
- `scale` 의 값이 `single` 의 두 배가 나오면 **실패다.** 통과 속도가 서버당으로 새고 있다는 뜻이고,
  ShedLock(`RedisWaitingRoom.drain` 의 `@SchedulerLock`)이 안 걸린 것을 먼저 의심한다.
- 입장권이 0건이면 드레인 스케줄러가 아예 안 도는 것이다 —
  `docker compose logs coupon-service` 에서 `waiting-room-drain` 락 취득 여부를 본다.
- `Duration` 은 입장권 TTL(기본 30초)보다 짧아야 한다. 길면 앞쪽 입장권이 만료돼 적게 세어진다.
  `Rate` 는 통과 속도보다 커야 줄이 쌓인다. 둘 다 러너가 시작 전에 막는다.

### `journey`

```
  통과 후 발급 성공     = 2000 / 2000명
  실패(journey_failures) = 0
  상태 폴링 총 요청      = 17924
  1인당 폴링 횟수        = 평균 9.0, 최대 17
  대기 시간(ms)          = 평균 10,992, p95 19,889
```

(2026-08-18 실측, `run.ps1 journey -Users 2000`)

**폴링 총 요청 수가 이 방식의 비용이다.** 사용자를 기다리게 해서 발급 API 부하는 줄였지만,
대신 상태 조회 요청이 새로 생긴다. `journey_failures` 가 0 이 아니면 나머지 숫자는 읽지 않는다.

- **기본값 200명으로는 이 비용이 안 보인다.** 2초면 전원 통과라 1인당 폴링이 1.1회 —
  최소치에 눌린다. 비용을 보려면 `-Users 2000` 으로 돌린다.
- **폴링 총량은 사용자 수의 제곱에 비례한다.** 200명 219건 → 2,000명 17,924건, 즉
  사용자 10배에 폴링 **82배**다. 대기 시간이 사용자 수에 비례하고 폴링은 그 대기 시간에
  비례하기 때문이다 (`docs/availability-track.md` §3.5 에 검산이 있다).
- **`-Users` 는 2,800 근처가 천장이다.** `MAX_WAIT_SECONDS = 30` 이 상수로 박혀 있고
  대기 시간이 `N/100 + ~1.25초` 라서, 넘기면 꼬리가 `통과 대기시간 초과` 로 실패한다.
  입장권 TTL 도 같은 30초라 함께 올려야 한다.
- **두 조건의 숫자를 섞지 않는다.** 200명 기록은 기준으로 남겨 둔다.

### `gateway`

```
  어뷰저(1명) 통과 = 65 / 2001  (차단 1936, 실패 0)
  정상 사용자 통과 = 201 / 201  (차단 0, 실패 0)
  dropped_iterations = 0

PASS: 어뷰저는 한도(60건, 허용 48~72건)만큼만 통과하고 정상 사용자는 한 번도 안 막혔습니다
```

(2026-08-18 실측)

- **한도는 토큰 버킷이다.** 순간 `burst`(10)개를 먼저 쓰고, 그 뒤로는 초당 `replenish`(5)개만
  채워진다. 그래서 10초짜리 실행의 기대치는 `10 + 5×10 = 60` 건이다.
  어뷰저가 2,001번을 때려도 서버에 닿는 것은 그만큼뿐이고 나머지는 앱 앞에서 429 로 끝난다.
- **`60` 이 아니라 `65` 가 나오는 것이 정상이다.** 채움이 밀리초로 연속하지 않고 **정수 초**
  경계에서 5개씩 들어간다(게이트웨이의 `request_rate_limiter.lua` 가 `redis.call('TIME')[1]` 을 쓴다).
  경계 1칸 = 5건이라 실행 시각에 따라 60 또는 65 가 나온다. ±20% 를 둔 이유가 이것이다.
  자세한 건 `docs/availability-track.md` §7.3.
- **k6 요약의 `http_req_failed` 가 88% 로 나오는데 이것도 정상이다.** 그 대부분이
  재려고 만든 429 다 (k6 은 4xx 를 `expected_response:false` 로 센다).
  **다른 트랙이면 여기서 읽기를 멈춰야 하는 숫자**라서 한 번 더 적어 둔다 —
  이 모드의 판정은 `http_req_failed` 가 아니라 아래 여섯 카운터로 한다.
- **`dropped_iterations` 를 먼저 읽는다.** 0 이 아니면 k6 이 예정대로 발사하지 못한 것이라,
  통과/차단 수가 한도를 뜻하지 않는다. 러너가 이 경우 나머지 판정을 건너뛰고 FAIL 을 낸다.
- **`정상 차단`이 0 이 아니면 버킷이 사용자별이 아니다.** 전역으로 걸린 것이므로
  `GatewayApplication.userIdKeyResolver` 를 먼저 의심한다.
- **`어뷰저 차단`이 0 이면 라우트에 필터가 안 붙은 것이다.** 한도 값이 아니라
  `application.yaml` 의 `RequestRateLimiter` 위치를 본다.
- **실패(200/429 외)가 섞이면 한도 문제가 아니다.** 게이트웨이 뒤(`coupon-service`)나
  라우트가 깨진 것이다 — `docker compose logs gateway coupon-service`.
- 기대치는 파라미터 기본값이 아니라 **실제로 뜬 게이트웨이 컨테이너의 `RATE_LIMIT_*`** 로 계산한다.
  compose 가 다른 값으로 떠 있으면 허용 구간이 통째로 틀리기 때문이다.

**라우트 경로가 안 맞아도 이 측정은 PASS 가 나온다.** k6 이 때리는 것은 `/api/waiting-room` 뿐인데
그 경로만 강의 원본과 같기 때문이다. 발급·사용·조회 경로가 게이트웨이를 안 거치는 상태(404)여도
어뷰저 컷은 정상으로 보인다 — rate limit 이 정작 발급을 안 지키는데 초록색이 찍히는 것이다.
러너가 측정에 들어가기 전에 `GET /api/v1/users/me/issuances` 를 8090 으로 찔러서 이 상태를 걸러낸다.

### `baseline`

```
  http_reqs      = 20000
  issue_failures = 0
```

(2026-08-18 실측, `coupon-service:reconcile-v3` — `http_req_failed 0.00%`,
`http_req_duration` med 0.86ms / p95 1.7ms, k6 VU 최대치 2)

`http_reqs` 가 대기실 없이 발급 API 까지 도달한 요청 수다. `single` 의 입장권 2,100건과
나란히 놓으면 대기실이 발급 경로에서 걷어낸 양이 보인다 — **20,000 → 2,100, 10분의 1**.

- **전부 성공했다는 것도 결과다.** 실패 0, p95 1.7ms, VU 2개로 1,000/s 를 채웠다.
  이 조건에서 발급 API 는 대기실 없이도 멀쩡했다는 뜻이다 (재고 100만이라 매진 경합이 없다).
  이 트랙이 보이는 것은 "인원을 10분의 1로 깎는다" 이지 "없으면 앱이 죽는다" 가 아니다 —
  `docs/availability-track.md` §3.8.

**대기실이 든 이미지에서는 잴 수 없다.** `CouponController` 의 입장권 게이트가 켜져 있어
발급 요청이 전부 403 으로 튕기고, 그러면 처리량이 아니라 "거절되는 속도" 를 재게 된다
(실제로 한 번 그랬다 — `docs/availability-track.md` §3.7). 러너가 리셋 전에 막고,
그래도 실패가 100% 로 나오면 숫자를 결과로 제시하지 않고 FAIL 을 낸다.

```powershell
# 돌아올 태그를 먼저 적어 둔다 — 러너가 라운드 머리에 "측정 대상 이미지:" 로 찍어 주고
# .env 의 COUPON_IMAGE_TAG 에도 남아 있다. 새 구현이 나올 때마다 이 값이 바뀐다.
.\build-and-run.ps1 -Tag reconcile-v3 -NoBuild     # 대기실 직전 이미지
.\scripts\availability\windows\run.ps1 baseline
.\build-and-run.ps1 -Tag <적어 둔 태그> -NoBuild    # 되돌리기
```

**브랜치를 바꾸는 것으로는 대신할 수 없다.** 재는 대상은 워킹트리가 아니라 떠 있는
컨테이너라서 `git checkout` 은 아무것도 안 바꾸고, 더구나 이 트랙의 하네스 자체가
대기실 커밋에서 들어왔다 — 이전 브랜치로 가면 돌릴 `run.ps1` 이 없다.
하네스는 HEAD 에 두고 재는 구현만 태그로 갈아 끼우는 이유가 이것이다 (CLAUDE.md).

## 원본(bash)과 다른 점

그대로 옮기면 **실패가 아니라 통과처럼 보이는** 자리들이라 전부 고쳐 두었다.

| 원본 | 이 판본 | 그대로 뒀다면 |
|---|---|---|
| 게이트 경로 `com/apiece/coupon/…` | `com/example/coupon/…` | 모든 모드가 `baseline` 으로 떨어짐 |
| `cd "$(dirname $0)/../../.."` | `Join-Path $PSScriptRoot '..\..\..'` | 저장소 루트보다 한 단계 위로 감 |
| 입장권 스캔 `waiting:{id}:pass:*` | `waiting:{id}:pass*` | 항상 0건 → `single`/`scale` 무조건 실패 |
| `/api/coupons/{id}/issue` | `/api/v1/coupons/{id}/issue` | 전 요청 404 인데 k6 은 정상 종료 |
| `QUANTITY` (원본 create_coupon 이 반영) | `create-coupon.ps1 -TotalQuantity 1000000` | 측정 도중 매진 |
| `trap … EXIT` | `try/finally` | 2번째 인스턴스가 남아 다음 측정을 오염 |
| `BASES=http://localhost:8081` | `http://coupon-service-2:8080` | k6 컨테이너 안에서 호스트 포트는 안 보인다 |
| k6 종료 코드로 판정 | 요약 JSON 의 지표로 판정 | exit 99 오작동에 끌려간다 (architecture.md 7절) |
| `BASE_URL=http://localhost:8090` | `http://gateway:8080` | 위와 같음 — k6 은 compose 네트워크 안이다 |
| predicate `/api/coupons/*/issue` | `/api/v1/coupons/*/issue` | **PASS 가 찍히는데 발급은 게이트웨이를 안 거친다** |
| `gateway_rate_limit.sh` 의 `DURATION`/`TOLERANCE` | `-GatewayDuration` / `-GatewayTolerancePercent` | 대기실 판정의 20s/30% 와 섞인다 |
| `docker compose up -d gateway` 후 방치 | `finally` 에서 `stop gateway` | 다음 라운드(1,000/s) 옆에서 CPU 를 쓴다 |

`verify.ps1` 에는 원본에 없는 **경합 재시도**가 있다. 드레인이 매초 100명을 통과시키므로
순번을 확인하는 사이에 드레인 틱이 끼면 `position` 이 0 으로 나온다. 결함이 아니라 경합이라
새 쿠폰으로 최대 3회 다시 돌리고, 계속 걸리면 그 사실을 적어 FAIL 로 낸다 (조용히 통과시키지 않는다).

## 파일

| 파일 | 하는 일 |
|---|---|
| `run.ps1` | 사전 확인 → 리셋 → 쿠폰 생성 → k6 → 판정. 여섯 모드 |
| `reset.ps1` | `coupon`/`issuance` TRUNCATE + Redis `FLUSHALL` (대기실 키까지 지운다 — 빼지 말 것) |
| `create-coupon.ps1` | 재고 100만짜리 쿠폰 1개 생성, ID 를 표준출력으로 |
| `verify.ps1` | 순번·멱등성·통과·발급·게이트 8항목 PASS/FAIL |
| `k6/*.js` | k6 시나리오 4종 (경로·접속 주소만 고친 원본) |

`gateway` 모드는 `coupon-gateway:latest` 이미지가 있어야 돈다. 러너는 빌드하지 않는다 —
없으면 커맨드를 안내하고 멈춘다.

```powershell
.\gradlew.bat :gateway:jibBuildTar          # jibDockerBuild 는 교착에 빠진다 (CLAUDE.md)
docker load -i gateway\build\jib-image.tar
```
