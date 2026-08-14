// 검증: "1인 1매만 쿠폰 발급되어야 한다".
// 사용자 1,000명이 30초 동안 초당 5,000번 요청 → 같은 사람이 여러 번 시도하게 됨.
// coupon.issued_quantity 와 실제 issuance 행 수가 다르면 발급 처리 중 race 가 일어난 것.
//
// scripts/load/duplicate_issuance.js (mac 로컬 k6 용) 의 Windows/Docker 판본.
// 부하 조건(rate, VU, USER_POOL)은 두 판본이 같아야 결과를 비교할 수 있다.
import http from 'k6/http';
import { check } from 'k6';

// compose 의 k6 서비스가 http://coupon-service:8080 을 넣어준다.
// 기본값은 나중에 로컬에 k6 을 설치해 직접 돌릴 경우를 위해 남겨둔다.
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';
const USER_POOL = 1000;

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

  // 같은 사용자가 다시 시도하면 409(ALREADY_ISSUED)가 정상이므로 200 을 기대하면 안 된다.
  // "요청이 앱까지 제대로 갔는가" 만 본다.
  check(res, {
    // 404 면 경로나 BASE_URL 이 틀렸다는 신호.
    'route exists (not 404)': (r) => r.status !== 404,
    // status 0 = 연결 자체가 실패(거절/타임아웃). TCP 단에서 튕긴 것을
    // 부하가 걸린 것으로 착각하면 안 된다.
    'connected (not status 0)': (r) => r.status !== 0,
  });
}
