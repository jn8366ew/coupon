#!/usr/bin/env bash
# part-4 시나리오 통합 러너. 5개 브랜치 (4-0, 4-1a, 4-1b, 4-1c, 4-2) 에서 동일하게 동작.
#
# 사용:
#   ./scripts/load/part-4/run.sh             # 두 시나리오 모두 실행 (워밍업 + 본 측정)
#   ./scripts/load/part-4/run.sh policy      # ① 발급 API 쿠폰 정보 조회 요청 급증만
#   ./scripts/load/part-4/run.sh sellout     # ② 매진 후 새로고침만
#   ./scripts/load/part-4/run.sh --once policy # 워밍업 생략
#
# 핵심: 서비스 프로세스는 띄운 채로 두고 회차 사이에 reset.sh 로 DB/Redis 만 비운다.

set -euo pipefail
cd "$(dirname "$0")/../../.."

WARMUP=true
if [[ "${1:-}" == "--once" ]]; then WARMUP=false; shift; fi

SCENARIOS="${1:-all}"

read_metrics() {
  curl -fsS http://localhost:8080/metrics/cache | jq -c '.'
}

reset_metrics() {
  curl -fsS -X POST http://localhost:8080/metrics/cache/reset >/dev/null
}

run_policy_once() {
  local label="$1"
  printf '\n\033[1;36m===== ① 발급 API 쿠폰 정보 조회 요청 급증: %s =====\033[0m\n' "$label"
  ./scripts/load/reset.sh
  local coupon_id
  coupon_id=$(./scripts/load/part-4/create_issue_policy_coupon.sh)
  reset_metrics
  # threshold (p99<200) 깨지는 게 4-0 ~ 4-1b 에서 정상. SWR (4-1c) 에서 통과.
  k6 run -e COUPON_ID="$coupon_id" scripts/load/part-4/coupon_burst.js || true
  printf '\n\033[1;33m카운터: \033[0m%s\n' "$(read_metrics)"
}

run_sellout_once() {
  local label="$1"
  printf '\n\033[1;36m===== ② 매진 후 새로고침: %s =====\033[0m\n' "$label"
  ./scripts/load/reset.sh
  local coupon_id
  coupon_id=$(./scripts/load/part-4/create_small_coupon.sh)
  COUPON_ID="$coupon_id" ./scripts/load/part-4/sell_out.sh
  reset_metrics
  # 4-2 적용 후엔 threshold (p99<100) 통과해야 한다.
  k6 run -e COUPON_ID="$coupon_id" scripts/load/part-4/post_sellout_refresh.js || true
  printf '\n\033[1;33m카운터: \033[0m%s\n' "$(read_metrics)"
}

run_policy() {
  if $WARMUP; then
    run_policy_once "워밍업 1/2"
    run_policy_once "본 측정 2/2 (steady-state)"
  else
    run_policy_once "본 측정 1/1"
  fi
}

run_sellout() {
  if $WARMUP; then
    run_sellout_once "워밍업 1/2"
    run_sellout_once "본 측정 2/2 (steady-state)"
  else
    run_sellout_once "본 측정 1/1"
  fi
}

case "$SCENARIOS" in
  policy) run_policy ;;
  sellout) run_sellout ;;
  all) run_policy; run_sellout ;;
  *) printf 'unknown scenario: %s (policy | sellout | all)\n' "$SCENARIOS"; exit 1 ;;
esac