// 대기실 진입 요청 급증. 줄을 채워 드레인이 매초 통과 속도만큼 일하게 만든다
// (판정은 k6 이 아니라 run.ps1 이 세는 Redis 입장권 수다).
// BASES 에 콤마로 여러 인스턴스를 주면 VU 가 라운드로빈으로 나눠 진입한다.
//
// scripts/availability/waiting_room_flood.js (mac 원본) 의 Windows 판본. 부하 조건은 원본과 같다.
// 대기실 경로는 /api/waiting-room 으로 v1 이 없다 (WaitingRoomController). 그래서 경로 수정이 없다.
// 다만 이 판본은 k6 컨테이너 안에서 돌므로 BASES 는 호스트 포트가 아니라 compose 서비스 이름을 받는다.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const COUPON_ID = __ENV.COUPON_ID || '1';
const BASES = (__ENV.BASES || 'http://coupon-service:8080').split(',');
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
