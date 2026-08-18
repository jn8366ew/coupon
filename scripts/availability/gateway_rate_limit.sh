#!/usr/bin/env bash
# part-6-2 Gateway Rate Limit 검증. 어뷰저 요청 급증 중 서버(앱 8080)에 도달하는 건 토큰 한도만큼뿐,
# 나머지는 Gateway(8090)에서 429 로 컷. 사용: ./scripts/load/part-6/gateway_rate_limit.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."

BASE="${BASE_URL:-http://localhost:8090}"
APPLICATION_BASE="${APPLICATION_BASE_URL:-http://localhost:8080}"
DURATION="${DURATION:-10s}"
ABUSER_RATE="${ABUSER_RATE:-200}"
NORMAL_RATE="${NORMAL_RATE:-20}"
REPLENISH_RATE="${RATE_LIMIT_REPLENISH:-5}"
BURST_CAPACITY="${RATE_LIMIT_BURST:-10}"
TOLERANCE_PERCENT="${TOLERANCE_PERCENT:-20}"
QUANTITY="${QUANTITY:-1000000}"

[[ -f gateway/src/main/kotlin/com/apiece/gateway/GatewayApplication.kt ]] || {
  echo "gateway_rate_limit은 part-6-2-edge-rate-limit에서 실행할 수 있다" >&2
  exit 1
}

[[ "$DURATION" =~ ^[1-9][0-9]*s$ ]] || { echo "DURATION은 10s처럼 초 단위로 입력해야 한다" >&2; exit 1; }
(( ABUSER_RATE > REPLENISH_RATE )) || {
  echo "ABUSER_RATE는 replenish rate(${REPLENISH_RATE}/s)보다 커야 제한을 검증할 수 있다" >&2
  exit 1
}

printf '\n\033[1;36m===== part-6-2 Gateway Rate Limit: 어뷰저 컷 + 정상 통과 =====\033[0m\n'
docker compose up -d gateway >/dev/null
ready=false
for _ in $(seq 1 60); do
  if curl -fsS "$BASE/api/users/me/issuances" -H "X-User-Id: 1" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == "true" ]] || { echo "게이트웨이 준비 실패" >&2; exit 1; }

./scripts/load/reset.sh >/dev/null
coupon_id=$(BASE_URL="$APPLICATION_BASE" QUANTITY="$QUANTITY" ./scripts/load/create_coupon.sh)
printf '쿠폰 %s 생성. 어뷰저(한 id)와 정상(매번 다른 id)을 게이트웨이로 동시 전송.\n' "$coupon_id"

k6 run -e COUPON_ID="$coupon_id" -e BASE_URL="$BASE" -e DURATION="$DURATION" \
  -e ABUSER_RATE="$ABUSER_RATE" -e NORMAL_RATE="$NORMAL_RATE" \
  -e REPLENISH_RATE="$REPLENISH_RATE" -e BURST_CAPACITY="$BURST_CAPACITY" \
  -e TOLERANCE_PERCENT="$TOLERANCE_PERCENT" \
  scripts/load/part-6/gateway_rate_limit.js

printf '\033[0;37m어뷰저 요청도 burst와 초당 허용량만큼은 서버에 닿고, 나머지는 Gateway에서 429로 제한된다.\n'
printf '정상 사용자는 각자 버킷이라 한 번도 안 막힌다 (k6 normal_blocked=0).\033[0m\n'
