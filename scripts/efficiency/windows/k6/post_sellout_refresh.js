// 시나리오 ②: 매진 후 새로고침 폭주. 매진 시그널 효과 측정.
//
// scripts/efficiency/post_sellout_refresh.js (mac 로컬 k6 용) 의 Windows/Docker 판본.
// 부하 조건(rate, VU, USER_POOL)은 두 판본이 같아야 결과를 비교할 수 있다.
//
// 원본에서 바꾼 것은 네 가지뿐이고, 전부 이 저장소에서 실제로 당한 함정에 대한 대응이다.
//   1. 경로 /api/coupons -> /api/v1/coupons   (원본대로면 전 요청 404)
//   2. check() 두 개 추가                     (404·연결실패를 조용히 통과시키지 않으려고)
//   3. status 0 을 지연 분포에서 제외          (아래 "왜 status 0 을 빼는가")
//   4. summaryTrendStats 에 p(99) 추가        (기본 요약은 p(95) 까지만 낸다)
//
// 사전 조건: 재고를 100 장으로 만든 쿠폰을 100 명이 발급해 매진시켜 둔다 (sell-out.ps1).
// 그 다음 30 초 동안 4,000 req/s 의 발급 폭주를 보낸다.
//
// 측정 포인트:
//   - 4-0 ~ 4-1c (시그널 없음): 모든 요청이 Lua 까지 들어와 -1 (매진) 응답.
//   - 4-2 (시그널 적용): 컨트롤러 진입 직후 fast-path 에서 잘려 Lua 호출 0 수렴.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';

// compose 의 k6 서비스가 http://coupon-service:8080 을 넣어준다.
// 기본값은 나중에 로컬에 k6 을 설치해 직접 돌릴 경우를 위해 남겨둔다.
const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';        // docker compose run -e COUPON_ID=... 로 주입
const USER_POOL = 50000;        // 매진 후 새로고침이라 발급 성공은 0. 사용자 풀은 분포용.

const issueLatency = new Trend('issue_latency', true);
const status2xx = new Counter('status_2xx');
const status409 = new Counter('status_409_sold_out_or_dup');
const statusOther = new Counter('status_other');
// status 0 = 앱이 응답한 게 아니라 TCP 단에서 튕긴 것. 아래 이유로 따로 센다.
const statusConnError = new Counter('status_conn_error');

export const options = {
    scenarios: {
        post_sellout: {
            executor: 'constant-arrival-rate',
            rate: 4000, timeUnit: '1s', duration: '30s',  // 4,000 req/s × 30s = 120,000 회
            preAllocatedVUs: 2000, maxVUs: 5000,
        },
    },
    // 기본 요약은 p(90)/p(95) 까지만 낸다. 이 트랙의 관심사가 p99 라 명시적으로 넣는다.
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
    // 4-2 적용 후 fast-path 거절은 수 ms 안에 끝나야 한다.
    // (k6 은 threshold 가 깨지면 exit 99 를 낸다. run.ps1 이 그 코드를 허용한다.)
    thresholds: {
        'issue_latency': ['p(99)<100'],
    },
};

export default function () {
    // 사용자 ID 는 매진 시킨 100 명 (1~100) 을 피해 100 이상으로 보낸다.
    // 그러지 않으면 중복 발급으로 빨려 들어가서 측정 분포가 흐려진다.
    const userId = Math.floor(Math.random() * USER_POOL) + 101;
    const res = http.post(`${BASE}/api/v1/coupons/${COUPON_ID}/issue`, null, {
        headers: { 'X-User-Id': String(userId) },
    });

    check(res, {
        // 404 면 경로나 BASE_URL 이 틀린 것. 이 검사가 없으면 전 요청이 404 여도
        // k6 은 조용히 성공하고 카운터만 0 으로 나온다.
        'route exists (not 404)': (r) => r.status !== 404,
        // status 0 = 연결 자체가 실패(거절/타임아웃). 404 검사만으로는 0 을 못 잡는다.
        'connected (not status 0)': (r) => r.status !== 0,
        // 500 은 위 두 검사를 모두 통과한다. 이 시나리오는 거절(409)이 정상이라
        // 상태 코드 카운터만으로는 "정상 거절" 과 "서버 오류" 가 잘 안 구분된다.
        'no server error (not 5xx)': (r) => r.status < 500,
    });

    // 왜 status 0 을 지연 분포에서 빼는가
    //
    //   연결이 거부되면 res.timings.duration 이 0ms 에 가깝게 기록된다. 그대로 Trend 에 넣으면
    //   "빠른 응답" 이 대량으로 섞여 p99 가 실제보다 좋게 나온다. 열린 모델로 4,000rps 를 던지는
    //   이 조건은 response 트랙(5,000rps 에서 15~27% 발생, docs/load-test-k6.md 12.7.3) 과 같다.
    //
    //   그래서 issue_latency 는 "앱이 실제로 응답한 요청의 분포" 다.
    //   status_conn_error 가 크면 그만큼 살아남은 요청만 본 수치라는 뜻이므로 같이 읽어야 한다.
    //   특히 4-2 의 fast-path 효과를 볼 때 이걸 안 빼면 "빨라진 것" 과 "튕긴 것" 이 구분되지 않는다.
    if (res.status === 0) {
        statusConnError.add(1);
        return;
    }

    issueLatency.add(res.timings.duration);
    if (res.status >= 200 && res.status < 300) status2xx.add(1);
    else if (res.status === 409) status409.add(1);   // SOLD_OUT — 이 시나리오의 정상 응답
    else statusOther.add(1);                         // 5xx, 타임아웃 등 비정상
}
