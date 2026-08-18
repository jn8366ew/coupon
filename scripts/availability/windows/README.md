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

`gateway`(엣지 rate limit) 모드는 아직 옮기지 않았다 — `gateway/` 모듈도 compose 서비스도 없다.

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
```

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
  통과 후 발급 성공     = 200 / 200명
  실패(journey_failures) = 0
  상태 폴링 총 요청      = 412
  1인당 폴링 횟수        = 평균 2.1, 최대 3
  대기 시간(ms)          = 평균 1120, p95 2010
```

**폴링 총 요청 수가 이 방식의 비용이다.** 사용자를 기다리게 해서 발급 API 부하는 줄였지만,
대신 상태 조회 요청이 새로 생긴다. 통과 속도를 올리면 줄고, 낮추면 늘어난다.
`journey_failures` 가 0 이 아니면 나머지 숫자는 읽지 않는다.

### `baseline`

`http_reqs` 가 대기실 없이 발급 API 까지 도달한 요청 수다. `single` 의 입장권 수와 나란히 놓으면
대기실이 발급 경로에서 걷어낸 양이 보인다.

**대기실이 든 이미지에서는 잴 수 없다.** `CouponController` 의 입장권 게이트가 켜져 있어
발급 요청이 전부 403 으로 튕기고, 그러면 처리량이 아니라 "거절되는 속도" 를 재게 된다
(실제로 한 번 그랬다 — `docs/availability-track.md` §3.7). 러너가 리셋 전에 막고,
그래도 실패가 100% 로 나오면 숫자를 결과로 제시하지 않고 FAIL 을 낸다.

```powershell
.\build-and-run.ps1 -Tag reconcile-v3 -NoBuild     # 대기실 직전 이미지
.\scripts\availability\windows\run.ps1 baseline
.\build-and-run.ps1 -Tag waiting-room -NoBuild     # 되돌리기
```

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

`verify.ps1` 에는 원본에 없는 **경합 재시도**가 있다. 드레인이 매초 100명을 통과시키므로
순번을 확인하는 사이에 드레인 틱이 끼면 `position` 이 0 으로 나온다. 결함이 아니라 경합이라
새 쿠폰으로 최대 3회 다시 돌리고, 계속 걸리면 그 사실을 적어 FAIL 로 낸다 (조용히 통과시키지 않는다).

## 파일

| 파일 | 하는 일 |
|---|---|
| `run.ps1` | 사전 확인 → 리셋 → 쿠폰 생성 → k6 → 판정. 다섯 모드 |
| `reset.ps1` | `coupon`/`issuance` TRUNCATE + Redis `FLUSHALL` (대기실 키까지 지운다 — 빼지 말 것) |
| `create-coupon.ps1` | 재고 100만짜리 쿠폰 1개 생성, ID 를 표준출력으로 |
| `verify.ps1` | 순번·멱등성·통과·발급·게이트 8항목 PASS/FAIL |
| `k6/*.js` | k6 시나리오 3종 (경로만 고친 원본) |
