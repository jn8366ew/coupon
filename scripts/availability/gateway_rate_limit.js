// Gateway Rate Limit 검증. Gateway로 어뷰저(같은 사용자)와 정상(각자 다른 사용자)을 동시에 보낸다.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const COUPON_ID = __ENV.COUPON_ID || '1';
const BASE = __ENV.BASE_URL || 'http://localhost:8090';
const DURATION = __ENV.DURATION || '10s';
const ABUSER_RATE = Number(__ENV.ABUSER_RATE || 200);
const NORMAL_RATE = Number(__ENV.NORMAL_RATE || 20);
const REPLENISH_RATE = Number(__ENV.REPLENISH_RATE || 5);
const BURST_CAPACITY = Number(__ENV.BURST_CAPACITY || 10);
const TOLERANCE_PERCENT = Number(__ENV.TOLERANCE_PERCENT || 20);
const durationMatch = DURATION.match(/^([1-9][0-9]*)s$/);
if (!durationMatch) throw new Error('DURATION은 10s처럼 초 단위로 입력해야 한다');

const durationSeconds = Number(durationMatch[1]);
const expectedAbuserPassed = BURST_CAPACITY + REPLENISH_RATE * durationSeconds;
const expectedNormalPassed = NORMAL_RATE * durationSeconds;
const lower = (value) => Math.floor(value * (100 - TOLERANCE_PERCENT) / 100);
const upper = (value) => Math.ceil(value * (100 + TOLERANCE_PERCENT) / 100);

const abuserPassed = new Counter('abuser_passed');
const abuserBlocked = new Counter('abuser_blocked');
const abuserFailed = new Counter('abuser_failed');
const normalPassed = new Counter('normal_passed');
const normalBlocked = new Counter('normal_blocked');
const normalFailed = new Counter('normal_failed');

export const options = {
  scenarios: {
    abuser: {
      executor: 'constant-arrival-rate', exec: 'abuser',
      rate: ABUSER_RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: 200, maxVUs: 400,
    },
    normal: {
      executor: 'constant-arrival-rate', exec: 'normal',
      rate: NORMAL_RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: 50, maxVUs: 100,
    },
  },
  thresholds: {
    dropped_iterations: ['count==0'],
    normal_blocked: ['count==0'],  // 정상 사용자는 한 번도 안 막혀야
    abuser_blocked: ['count>0'],   // 어뷰저는 Gateway에서 컷돼야
    abuser_passed: [`count>=${lower(expectedAbuserPassed)}`, `count<=${upper(expectedAbuserPassed)}`],
    normal_passed: [`count>=${lower(expectedNormalPassed)}`],
    abuser_failed: ['count==0'],
    normal_failed: ['count==0'],
  },
};

export function abuser() {
  const res = http.post(`${BASE}/api/waiting-room/${COUPON_ID}`, null, {
    headers: { 'X-User-Id': '424242' },
  });
  if (res.status === 200) abuserPassed.add(1);
  else if (res.status === 429) abuserBlocked.add(1);
  else abuserFailed.add(1);
}

export function normal() {
  const userId = String(9_000_000_000 + __VU * 1_000_000 + __ITER);
  const res = http.post(`${BASE}/api/waiting-room/${COUPON_ID}`, null, {
    headers: { 'X-User-Id': userId },
  });
  if (res.status === 200) normalPassed.add(1);
  else if (res.status === 429) normalBlocked.add(1);
  else normalFailed.add(1);
}
