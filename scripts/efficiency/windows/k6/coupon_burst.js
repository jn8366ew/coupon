// 시나리오 ①: 발급 API 의 쿠폰 정보 조회 요청 급증. 캐시 stampede 와 단계별 해소를 본다.
//
// scripts/efficiency/coupon_burst.js (mac 로컬 k6 용) 의 Windows/Docker 판본.
// 부하 조건(rate, VU, duration)은 두 판본이 같아야 결과를 비교할 수 있다.
//
// 원본에서 바꾼 것은 다섯 가지뿐이고, 넷은 이 저장소에서 실제로 당한 함정에 대한 대응이다.
//   1. 경로 /api/coupons -> /api/v1/coupons   (원본대로면 전 요청 404)
//   2. check() 두 개 추가                     (404·연결실패를 조용히 통과시키지 않으려고)
//   3. status 0 을 지연 분포에서 제외          (아래 "왜 status 0 을 빼는가")
//   4. summaryTrendStats 에 p(99) 추가        (기본 요약은 p(95) 까지만 낸다)
//   5. 409 카운터 추가                        (아래 "왜 409 가 정상인가")
//
// 시작 전 쿠폰에 POST /api/v1/coupons/{id}/issue 를 500 req/s 로 30초간 쏟아붓는다.
// issue 는 NotStarted 로 끝나므로 재고 차감이나 Kafka 발행 없이 쿠폰 정보 조회까지만 실행한다.
//
// 측정 포인트:
//   - p99 응답 시간 (issue_policy_latency)
//   - couponDbReads (k6 직전 /metrics/cache/reset 으로 0 -> 종료 후 /metrics/cache GET)
//
// 조건 주의: 이 시나리오의 수치는 아래 두 값에 통째로 좌우된다.
// docker-compose.yml 이 기본값을 주고(TTL 1000ms, 조회 지연 100ms), 셸에서 같은 이름의
// 환경변수로 덮을 수 있다. 하네스는 강제하지 않고 run.ps1 이 실제 적용값을 찍기만 한다.
//
//   COUPON_CACHE_TTL_MS                     1000  캐시 만료. 짧을수록 stampede 윈도우가 자주 온다
//   COUPON_CACHE_SIMULATED_LOAD_LATENCY_MS   100  DB 조회에 심는 인위적 지연.
//                                                 0 이면 조회가 1ms 라 캐시 효과가 p99 에 안 드러난다
//
// 둘 중 하나라도 다르면 이전 측정과 비교가 성립하지 않는다. 실제로 4-0 은 10000/0,
// 4-1 은 1000/100 에서 쟀다 (docs/load-test-k6.md §18, §19).
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics'; // Trend: 분포 (avg/p95/p99), Counter: 누적 합

// compose 의 k6 서비스가 http://coupon-service:8080 을 넣어준다.
// 기본값은 나중에 로컬에 k6 을 설치해 직접 돌릴 경우를 위해 남겨둔다.
const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';        // docker compose run -e COUPON_ID=... 로 주입

const issuePolicyLatency = new Trend('issue_policy_latency', true);
const status2xx = new Counter('status_2xx');
// 왜 409 가 정상인가
//   startsAt 이 미래인 쿠폰이라 NotStartedException 이 던져지고, 그건 HTTP 409 다
//   (support/DomainException.kt). 즉 이 시나리오는 요청 전부가 409 로 끝나는 것이 정상이다.
//   원본은 이걸 status_other 로 뭉뚱그려서 "전부 비정상" 처럼 보인다.
const status409 = new Counter('status_409_not_started');
const statusOther = new Counter('status_other');
// status 0 = 앱이 응답한 게 아니라 TCP 단에서 튕긴 것. 아래 이유로 따로 센다.
const statusConnError = new Counter('status_conn_error');

export const options = {
    scenarios: {
        issue_policy_burst: {
            executor: 'constant-arrival-rate',
            rate: 500, timeUnit: '1s', duration: '30s',  // 500 req/s × 30s = 15,000 회
            preAllocatedVUs: 500, maxVUs: 1000,
        },
    },
    // 기본 요약은 p(90)/p(95) 까지만 낸다. 이 트랙의 관심사가 p99 라 명시적으로 넣는다.
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
    // 이 threshold 는 판정 기준이 아니다 — 참고용으로만 본다.
    // 실측(TTL 1000 / latency 100, docs/load-test-k6.md §18~§20):
    //   cache-4-0        p(99) 747.91ms  깨짐
    //   rediscache-4-1   p(99) 102.37ms  통과
    //   single-flight    p(99) 103.11ms  통과 — DB 조회는 46배 줄었는데 p99 는 제자리다
    // 즉 200ms 선은 stampede 개선을 구분하지 못한다. 이 시나리오의 판정은 couponDbReads 로 한다.
    // p99 가 지표가 되는 것은 대기 자체가 사라지는 SWR 부터다.
    // (k6 은 threshold 가 깨지면 exit 99 를 낸다. run.ps1 이 그 코드를 허용한다.)
    thresholds: {
        'issue_policy_latency': ['p(99)<200'],
    },
};

export default function () {
    const userId = String(6000000000 + __VU);
    const res = http.post(`${BASE}/api/v1/coupons/${COUPON_ID}/issue`, null, {
        headers: { 'X-User-Id': userId },
    });

    check(res, {
        // 404 면 경로나 BASE_URL 이 틀린 것. 이 검사가 없으면 전 요청이 404 여도
        // k6 은 조용히 성공하고 카운터만 0 으로 나온다.
        'route exists (not 404)': (r) => r.status !== 404,
        // status 0 = 연결 자체가 실패(거절/타임아웃). 404 검사만으로는 0 을 못 잡는다.
        'connected (not status 0)': (r) => r.status !== 0,
        // 500 은 위 두 검사를 모두 통과한다. single-flight 도입 때 Lua 파일명이 한 글자
        // 틀려 전 요청이 500 이었는데 checks 는 100% 로 나왔다. 그때 이 줄이 있었다면
        // 즉시 66% 로 드러났다.
        'no server error (not 5xx)': (r) => r.status < 500,
    });

    // 왜 status 0 을 지연 분포에서 빼는가
    //
    //   연결이 거부되면 res.timings.duration 이 0ms 에 가깝게 기록된다. 그대로 Trend 에 넣으면
    //   "빠른 응답" 이 대량으로 섞여 p99 가 실제보다 좋게 나온다 (docs/load-test-k6.md 12.7.3).
    //   그래서 issue_policy_latency 는 "앱이 실제로 응답한 요청의 분포" 다.
    //   status_conn_error 가 크면 그만큼 살아남은 요청만 본 수치라는 뜻이므로 같이 읽어야 한다.
    if (res.status === 0) {
        statusConnError.add(1);
        return;
    }

    issuePolicyLatency.add(res.timings.duration);
    if (res.status >= 200 && res.status < 300) status2xx.add(1);
    else if (res.status === 409) status409.add(1);   // NotStarted — 이 시나리오의 정상 응답
    else statusOther.add(1);                         // 5xx, 타임아웃 등 비정상
}
