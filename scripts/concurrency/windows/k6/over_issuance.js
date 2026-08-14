// 검증: "재고만큼만 발급되어야 한다".
// 사용자 20,000명이 30초 동안 초당 5,000번 요청 → 5,000장 재고를 두고 다 같이 경쟁.
// 실제 발급된 issuance 행 수가 5,000장을 넘으면 과발급 결함.
//
// scripts/concurrency/load/over_issuance.js (mac 로컬 k6 용) 의 Windows/Docker 판본.
// 부하 조건(rate, VU, USER_POOL)은 두 판본이 같아야 결과를 비교할 수 있다.
import http from 'k6/http';
import { check } from 'k6';

// compose 의 k6 서비스가 http://coupon-service:8080 을 넣어준다.
// 기본값은 나중에 로컬에 k6 을 설치해 직접 돌릴 경우를 위해 남겨둔다.
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';
const USER_POOL = 20000;

export const options = {
  scenarios: { issue: {
    executor: 'constant-arrival-rate',
    rate: 5000, timeUnit: '1s', duration: '30s',
    preAllocatedVUs: 2000, maxVUs: 5000,
  } },
};

export default function () {
  const userId = Math.floor(Math.random() * USER_POOL) + 1;
  const res = http.post(`${BASE_URL}/api/v1/coupons/${COUPON_ID}/issue`, null, {
    headers: { 'X-User-Id': String(userId) },
  });

  // 재고 5,000장에 요청 150,000건이라 409(SOLD_OUT/ALREADY_ISSUED)가 대부분인 것이 정상이다.
  // 그래서 200 을 기대하면 안 되고, "요청이 앱까지 제대로 갔는가" 만 본다.
  check(res, {
    // 404 면 경로나 BASE_URL 이 틀린 것. 이 검사가 없으면 전 요청이 404 여도
    // k6 은 조용히 성공하고 verify 는 "결함 없음(PASS)" 이라는 정반대 결론을 낸다.
    'route exists (not 404)': (r) => r.status !== 404,
    // status 0 = 연결 자체가 실패(거절/타임아웃). 앱이 응답한 게 아니라 TCP 단에서
    // 튕긴 것이라 부하가 걸린 것으로 착각하면 안 된다. 404 검사만으로는 0 을 못 잡는다.
    'connected (not status 0)': (r) => r.status !== 0,
  });
}
