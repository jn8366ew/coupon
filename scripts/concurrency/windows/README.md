# 정확성 부하 테스트 (Windows)

`scripts/concurrency/load/` 의 mac 용 스크립트(bash + 로컬 k6 + jq)를 Windows 환경으로 옮긴 것.
**원본은 건드리지 않았다.** 두 판본은 부하 조건(rate, VU, USER_POOL)이 같아야 결과를 비교할 수 있다.

응답시간(P99)을 재는 트랙은 따로 있다 → `scripts/response/windows/README.md`

| | mac (`concurrency/load/`) | Windows (`concurrency/windows/`) |
|---|---|---|
| 셸 | bash | PowerShell 5.1+ |
| k6 | 로컬 설치 (`brew install k6`) | compose 의 `k6` 서비스 (설치 불필요) |
| JSON 파싱 | `jq` | `Invoke-RestMethod` (기본 제공) |
| 앱 주소 | `localhost:8080` | 컨테이너 안에서 `coupon-service:8080` |

## 사전 준비

- Docker Desktop
- `.\build-and-run.ps1` 로 앱 기동 → `docker compose ps` 에서 mysql healthy, coupon-service Up

k6 은 `grafana/k6:2.2.0` 이미지로 돈다. `latest` 가 아니라 태그를 고정한 이유는
세 브랜치 결과를 비교하려면 러너가 동일해야 하기 때문이다.
compose 의 `profiles: ["load"]` 덕분에 평소 `docker compose up -d` 에는 뜨지 않는다.

## 실행 (프로젝트 루트에서)

```powershell
# 1) 과발급 검증 (재고만큼만 발급되어야 한다)
.\scripts\concurrency\windows\load-test.ps1 over_issuance

# 2) 중복발급 검증 (1인 1매만 쿠폰 발급되어야 한다)
.\scripts\concurrency\windows\load-test.ps1 duplicate_issuance
```

`load-test.ps1` 이 **쿼리 로그 끄기 → 리셋 → 쿠폰 생성 → k6 → 검증**을 한 번에 돌리고
요약 JSON 을 `build\k6\<시나리오>.json` 에 남긴다. 한 사이클에 1분쯤 걸린다.

쿼리 로그는 `docker-compose.loadtest.yml` 로 끈다. 스크립트가 적용한 뒤
`docker inspect` 로 **실제 반영됐는지 확인**하고, 안 되어 있으면 측정하지 않고 멈춘다.
성능 때문이 아니라(그 가설은 기각됐다 — `docs/load-test-k6.md` 7절) 부하 한 번에
로그가 수백만 줄 쌓여 `docker compose logs` 를 못 쓰게 되기 때문이다.

무슨 SQL 이 나가는지 봐야 하면 `-KeepLogging` 을 준다.
끝난 뒤 개발 모드로 돌아가려면 `docker compose up -d coupon-service`.

### 구현 전환 (naive / pessimistic / ...)

구현은 브랜치가 아니라 **이미지 태그**로 나눈다.

```powershell
.\build-and-run.ps1 -Tag pessimistic     # 빌드 + 기동
.\scripts\concurrency\windows\load-test.ps1 over_issuance
#   → 화면에 "측정 대상 이미지: coupon-service:pessimistic"
#   → build\k6\over_issuance-pessimistic.json

.\build-and-run.ps1 -Tag naive           # 되돌려서 비교
```

태그는 `.env` 에 기록되어 이후 모든 `docker compose` 명령에 적용된다.
요약 JSON 파일명에 태그가 붙으므로 구현별 결과가 서로 덮어쓰지 않는다.
자세한 내용은 `docs/load-test-k6.md` 3절.

단계를 나눠 돌리려면:

```powershell
.\scripts\concurrency\windows\reset.ps1
$couponId = .\scripts\concurrency\windows\create-coupon.ps1
docker compose run --rm -e COUPON_ID=$couponId k6 run /scripts/concurrency/windows/k6/over_issuance.js
.\scripts\concurrency\windows\verify.ps1 -CouponId $couponId
```

## 결과를 믿기 전에 확인할 것

지표를 자세히 읽는 법은 `docs/load-test-k6.md` 에 있다. 여기서는 최소 확인 항목만.

### 1. `route exists (not 404)` 가 100% 인가

100% 가 아니면 경로나 `BASE_URL` 이 틀린 것이고, **결과 표 전체가 무의미하다.**

이 검사가 필요한 이유: 요청이 전부 404 로 떨어져도 k6 은 정상 종료하고,
`verify` 는 발급 0건을 보고 `over_issuance=OK`, `count_match=OK` → **PASS** 를 출력한다.
즉 "동시성 결함이 없다"는 정반대 결론이 나온다.

> `scripts/concurrency/load/` 의 mac 판본과 `scripts/concurrency/api.sh` 는 아직 `/api/coupons` 를 호출하는데
> 실제 컨트롤러 경로는 `/api/v1/coupons` 다 (`CouponController.kt`). 그대로 돌리면 전부 404 다.
> Windows 판본에는 `/api/v1` 로 반영해 두었다.

### 2. `connected (not status 0)` 가 100% 인가

이게 실패하면 그만큼의 요청이 **앱에 닿지도 못하고 TCP 단에서 튕긴 것**이다.
앱이 느려서 늦게 응답한 것과는 완전히 다른 상황이라, 처리량·응답시간을 그대로 읽으면 안 된다.

2026-08-13 실측에서는 요청의 **66% 가 여기서 튕겼다.** `rate: 5000/s` 를 던지는데
앱이 소화하는 건 초당 290건 남짓이라 연결 수락 큐가 넘친 것이다.

### 3. `dropped_iterations` — 지금 설정의 한계 (미해결)

시나리오는 `rate: 5000/s × 30s = 150,000 요청`, `maxVUs: 5000` 이다.
`constant-arrival-rate` 는 열린 모델이라 앱이 못 따라오면 **보내지 못한 요청을 버린다**.
위 2번과 합쳐지면 대부분의 지표를 읽을 수 없게 된다.

**권장 대응**: 닫힌 모델로 바꿔 브랜치마다 **정확히 같은 요청 수**가 가게 한다.

```js
scenarios: { issue: {
  executor: 'shared-iterations',
  vus: 200,            // 동시성 — 경합엔 충분하고 연결 폭주는 없음
  iterations: 20000,   // 총 요청 수 — 브랜치와 무관하게 고정
  maxDuration: '5m',
} },
```

이러면 "20,000건을 몇 초에 처리했나" 를 브랜치끼리 직접 비교할 수 있다.
다만 이는 `scripts/concurrency/load/` 의 mac 판본과 부하 조건이 달라진다는 뜻이므로,
바꾼다면 양쪽 판본에 같이 반영해야 한다. **아직 적용하지 않았다.**

실측 수치와 분석 근거는 `docs/load-test-k6.md` 8절에 있다.

### 4. 결과 해석

`verify.ps1` 이 보여주는 컬럼과 판정 기준은 `scripts/concurrency/load/README.md` 의 "결과 해석" 절과 같다.
`part-2-1-load-test` 에서는 **`FAIL` 이 떠야 정상**이다 (v0 결함 재현이 목적).
여기서 PASS 가 뜨면 결함이 없는 게 아니라 부하가 안 걸린 것을 먼저 의심한다.

## 측정 순서

`part-2-1-load-test` (v0 결함 재현) → `part-2-2-pessimistic-lock` → `part-2-3-redis-lua`.
각 브랜치에서 위 실행을 반복하고 결과를 design 문서 6.3 절 표에 채운다.
요약 JSON 은 실행할 때마다 덮어써지므로 표에 넣을 값은 그때그때 옮겨 적는다.
