// 실제 클라이언트 여정: 한 번 진입하고, 통과할 때까지 폴링한 뒤 쿠폰을 발급한다.
// 폴링이 만드는 추가 요청량과 사용자 대기시간을 함께 측정한다.
import http from 'k6/http';
import { sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const COUPON_ID = __ENV.COUPON_ID || '1';
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const USERS = Number(__ENV.USERS || 200);
const POLL_INTERVAL_SECONDS = Number(__ENV.POLL_INTERVAL_SECONDS || 1);
const POLL_JITTER_SECONDS = Number(__ENV.POLL_JITTER_SECONDS || 0.25);
const MAX_WAIT_SECONDS = Number(__ENV.MAX_WAIT_SECONDS || 30);
const USER_ID_BASE = Number(__ENV.USER_ID_BASE || 1_000_000_000);

const statusPolls = new Counter('journey_status_polls');
const issuedUsers = new Counter('journey_issued_users');
const failures = new Counter('journey_failures');
const pollLatency = new Trend('journey_poll_latency', true);
const pollsPerUser = new Trend('journey_polls_per_user');
const waitingTime = new Trend('journey_waiting_time', true);

export const options = {
  scenarios: {
    client_journey: {
      executor: 'per-vu-iterations',
      vus: USERS,
      iterations: 1,
      maxDuration: `${MAX_WAIT_SECONDS + 10}s`,
    },
  },
  thresholds: {
    journey_failures: ['count==0'],
    journey_issued_users: [`count==${USERS}`],
  },
};

function fail(message, userId, status) {
  failures.add(1);
  console.error(`${message}: user=${userId}, status=${status}`);
}

function parseAdmission(response, userId) {
  try {
    return response.json('admitted');
  } catch (_) {
    fail('대기실 응답 파싱 실패', userId, response.status);
    return null;
  }
}

export default function () {
  const userId = String(USER_ID_BASE + __VU);
  const headers = { 'X-User-Id': userId };
  const startedAt = Date.now();
  let pollCount = 0;

  const enterResponse = http.post(`${BASE_URL}/api/waiting-room/${COUPON_ID}`, null, {
    headers,
    tags: { name: 'waiting_room_enter' },
  });
  if (enterResponse.status !== 200) {
    fail('대기실 진입 실패', userId, enterResponse.status);
    return;
  }
  let admitted = parseAdmission(enterResponse, userId);
  if (admitted === null) return;

  const deadline = startedAt + MAX_WAIT_SECONDS * 1000;
  while (!admitted && Date.now() < deadline) {
    sleep(POLL_INTERVAL_SECONDS + Math.random() * POLL_JITTER_SECONDS);

    const statusResponse = http.get(`${BASE_URL}/api/waiting-room/${COUPON_ID}`, {
      headers,
      tags: { name: 'waiting_room_status' },
    });
    statusPolls.add(1);
    pollCount += 1;
    pollLatency.add(statusResponse.timings.duration);

    if (statusResponse.status !== 200) {
      fail('상태 조회 실패', userId, statusResponse.status);
      return;
    }

    admitted = parseAdmission(statusResponse, userId);
    if (admitted === null) return;
  }

  pollsPerUser.add(pollCount);
  if (!admitted) {
    fail('통과 대기시간 초과', userId, 0);
    return;
  }

  waitingTime.add(Date.now() - startedAt);

  const issueResponse = http.post(`${BASE_URL}/api/coupons/${COUPON_ID}/issue`, null, {
    headers,
    tags: { name: 'coupon_issue' },
  });
  if (issueResponse.status !== 200) {
    fail('쿠폰 발급 실패', userId, issueResponse.status);
    return;
  }
  issuedUsers.add(1);
}
