// 시나리오 ①: 발급 API의 쿠폰 정보 조회 요청 급증. 캐시 stampede 와 단계별 해소를 보기 위한 측정.
//
// 시작 전 쿠폰에 POST /api/coupons/{id}/issue 를 동시 500 명이 30초간 호출한다.
// issue API 는 NotStarted 로 끝나므로 재고 차감이나 Kafka 발행 없이 쿠폰 정보 조회까지만 실행한다.
// 캐시 TTL 은 COUPON_CACHE_TTL_MS=1000 으로 1초 강제해 TTL 만료 직후 같은 키로
// 요청이 몰리는 모습을 단계별 (4-0 ~ 4-1c) 로 비교한다.
//
// 측정 포인트:
//   - p99 응답 시간 (issue_burst 와 같은 Trend 사용)
//   - couponDbReads (시나리오 시작 전 /metrics/cache/reset 으로 0 → 종료 시 /metrics/cache GET)
import http from 'k6/http';
import { Trend, Counter } from 'k6/metrics';

const COUPON_ID = __ENV.COUPON_ID || '1';
const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const issuePolicyLatency = new Trend('issue_policy_latency', true);
const status2xx = new Counter('status_2xx');
const statusOther = new Counter('status_other');

export const options = {
    scenarios: {
        issue_policy_burst: {
            executor: 'constant-arrival-rate',
            rate: 500, timeUnit: '1s', duration: '30s',  // 500 req/s × 30s = 15,000 회
            preAllocatedVUs: 500, maxVUs: 1000,
        },
    },
    // single-flight 도입 (4-1b) 이후엔 stampede 윈도우 안의 P99 가 여전히 튀므로
    // threshold 깨지는 게 정상. SWR (4-1c) 에서 통과.
    thresholds: {
        'issue_policy_latency': ['p(99)<200'],
    },
};

export default function () {
    const userId = String(6000000000 + __VU);
    const res = http.post(`${BASE}/api/coupons/${COUPON_ID}/issue`, null, {
        headers: { 'X-User-Id': userId },
    });
    issuePolicyLatency.add(res.timings.duration);
    if (res.status >= 200 && res.status < 300) status2xx.add(1);
    else statusOther.add(1);
}