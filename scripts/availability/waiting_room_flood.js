// 대기실 진입 요청 급증. 줄을 채워 드레인이 매초 통과 속도만큼 일하게 만든다 (run.sh가 Redis 입장권 수로 측정).
// BASES 에 콤마로 여러 인스턴스를 주면 VU 가 라운드로빈으로 나눠 진입한다.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const COUPON_ID = __ENV.COUPON_ID || '1';
const BASES = (__ENV.BASES || 'http://localhost:8080').split(',');
const RATE = Number(__ENV.RATE || 1000);
const DURATION = __ENV.DURATION || '20s';

const failures = new Counter('waiting_room_enter_failures');

export const options = {
  scenarios: {
    enter_flood: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: Math.min(RATE, 2000), maxVUs: 4000,
    },
  },
  thresholds: {
    waiting_room_enter_failures: ['count==0'],
  },
};

export default function () {
  const base = BASES[__VU % BASES.length];
  const userId = String(__VU * 10_000_000 + __ITER);
  const res = http.post(`${base}/api/waiting-room/${COUPON_ID}`, null, {
    headers: { 'X-User-Id': userId },
  });
  if (res.status !== 200) failures.add(1);
}
