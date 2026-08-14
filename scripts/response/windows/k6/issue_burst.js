// 측정: "발급 폭증" 시나리오. 사용자 응답 P99 를 본다.
// 동기 구현 -> 큐 디커플링 비교의 기준 시나리오.
//
// scripts/response/issue_burst.js (mac 로컬 k6 용) 의 Windows/Docker 판본.
// 부하 조건(rate, VU, USER_POOL)은 두 판본이 같아야 결과를 비교할 수 있다.
//
// 원본에서 바꾼 것은 네 가지뿐이고, 셋은 이 저장소에서 실제로 당한 함정에 대한 대응이다.
//   1. 경로 /api/coupons -> /api/v1/coupons   (원본대로면 전 요청 404)
//   2. status 0 을 지연 분포에서 제외         (아래 "왜 status 0 을 빼는가")
//   3. check() 두 개 추가                     (404·연결실패를 조용히 통과시키지 않으려고)
//   4. summaryTrendStats 에 p(99) 추가        (기본 요약은 p(95) 까지만 낸다)
//
// USER_POOL 이 재고(5,000)보다 충분히 커서 대부분의 요청은 매진(409 SOLD_OUT) 응답을 받는다.
// 우리가 보고 싶은 것은 "응답 시간 분포" 자체이지 발급 성공 수가 아니다.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics'; // Trend: 분포 (avg/p95/p99), Counter: 누적 합

// compose 의 k6 서비스가 http://coupon-service:8080 을 넣어준다.
// 기본값은 나중에 로컬에 k6 을 설치해 직접 돌릴 경우를 위해 남겨둔다.
const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';        // docker compose run -e COUPON_ID=... 로 주입
const USER_POOL = 20000;                          // 재고 5000 << 사용자 20000 -> 대부분 매진 응답

// 응답 시간 분포를 기록할 커스텀 메트릭. 두 번째 인자 true 는 "시간 단위로 표시"
const issueLatency = new Trend('issue_latency', true);
// 상태 코드별 누적 카운터. k6 요약에 status_2xx=5000 처럼 노출된다.
const status2xx = new Counter('status_2xx');
const status409 = new Counter('status_409_sold_out_or_dup');
const statusOther = new Counter('status_other');
// status 0 = 앱이 응답한 게 아니라 TCP 단에서 튕긴 것. 아래 이유로 따로 센다.
const statusConnError = new Counter('status_conn_error');

export const options = {
  scenarios: {
    burst: {
      // constant-arrival-rate: VU 수와 무관하게 "초당 N건" 을 강제로 쏟아부음.
      // 백엔드가 느려도 요청 페이스가 떨어지지 않아 진짜 부하 측정에 적합.
      executor: 'constant-arrival-rate',
      rate: 5000, timeUnit: '1s', duration: '30s', // 5000 req/s x 30s = 총 150,000 요청
      preAllocatedVUs: 2000, maxVUs: 5000,         // 동시 처리에 쓸 가상 사용자 풀 (요청 단위는 rate 가 결정)
    },
  },
  // 기본 요약은 p(90)/p(95) 까지만 낸다. 이 트랙의 관심사가 p99 라 명시적으로 넣는다.
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    // 큐 디커플링 효과 확인용 임계. 동기 구현에서는 깨지는 것이 정상이고,
    // 깨진다는 사실 자체가 이 트랙의 출발점이다.
    // (k6 은 threshold 가 깨지면 exit 99 를 낸다. run.ps1 이 그 코드를 허용한다.)
    'issue_latency': ['p(99)<500'],
  },
};

// 각 VU 가 반복 실행하는 단위. constant-arrival-rate 가 호출 횟수를 결정.
export default function () {
  const userId = Math.floor(Math.random() * USER_POOL) + 1;     // 1 ~ USER_POOL 중 랜덤
  const res = http.post(`${BASE}/api/v1/coupons/${COUPON_ID}/issue`, null, {
    headers: { 'X-User-Id': String(userId) },                    // 인증 대신 헤더로 사용자 식별
  });

  // 재고 5,000장에 요청 150,000건이라 409(SOLD_OUT/ALREADY_ISSUED)가 대부분인 것이 정상이다.
  // 그래서 200 을 기대하면 안 되고, "요청이 앱까지 제대로 갔는가" 만 본다.
  check(res, {
    // 404 면 경로나 BASE_URL 이 틀린 것. 이 검사가 없으면 전 요청이 404 여도
    // k6 은 조용히 성공하고 verify 는 "결함 없음(PASS)" 이라는 정반대 결론을 낸다.
    'route exists (not 404)': (r) => r.status !== 404,
    // status 0 = 연결 자체가 실패(거절/타임아웃). 404 검사만으로는 0 을 못 잡는다.
    'connected (not status 0)': (r) => r.status !== 0,
  });

  // 왜 status 0 을 지연 분포에서 빼는가
  //
  //   연결이 거부되면 res.timings.duration 이 0ms 에 가깝게 기록된다. 그대로 Trend 에 넣으면
  //   "빠른 응답" 이 대량으로 섞여 p99 가 실제보다 좋게 나온다. 열린 모델로 5,000rps 를 던지는
  //   지금 조건에서는 요청의 15~27% 가 여기 해당한다 (docs/load-test-k6.md 12.7.3).
  //
  //   그래서 issue_latency 는 "앱이 실제로 응답한 요청의 분포" 다. mac 원본의 p99 와 정의가
  //   다르지만, 원본은 경로가 404 라 이 저장소에서 잰 적이 없으므로 비교 대상이 없다.
  //   대신 status_conn_error 를 같이 읽어야 한다 — 이 값이 크면 p99 는 살아남은 요청만의 수치다.
  if (res.status === 0) {
    statusConnError.add(1);
    return;
  }

  issueLatency.add(res.timings.duration);                        // ms 단위 응답 시간 기록
  if (res.status >= 200 && res.status < 300) status2xx.add(1);   // 발급 성공
  else if (res.status === 409) status409.add(1);                 // 매진 or 중복 발급 (예상된 거절)
  else statusOther.add(1);                                       // 5xx, 타임아웃 등 비정상
}
