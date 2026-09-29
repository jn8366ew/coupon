#!/usr/bin/env bash
# 실제 클라이언트 여정 검증: POST 진입 -> GET 상태 폴링 -> 통과 후 POST 발급.
# 사용: USERS=200 POLL_INTERVAL_SECONDS=1 ./scripts/load/part-6/waiting_room_journey.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."

BASE="${BASE_URL:-http://localhost:8080}"
USERS="${USERS:-200}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-1}"
POLL_JITTER_SECONDS="${POLL_JITTER_SECONDS:-0.25}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-30}"
QUANTITY="${QUANTITY:-1000000}"

[[ -f src/main/kotlin/com/apiece/coupon/application/RedisWaitingRoom.kt ]] || {
  echo "waiting_room_journey는 part-6-1-waiting-room 이후에 실행할 수 있다" >&2
  exit 1
}

printf '\n\033[1;36m===== part-6 실제 사용자 여정: 진입 -> 폴링 -> 발급 =====\033[0m\n'

ready=false
for _ in $(seq 1 60); do
  if curl -fsS "$BASE/api/users/me/issuances" -H "X-User-Id: 1" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == "true" ]] || { echo "애플리케이션 준비 실패: $BASE" >&2; exit 1; }

./scripts/load/reset.sh >/dev/null
coupon_id=$(BASE_URL="$BASE" QUANTITY="$QUANTITY" ./scripts/load/create_coupon.sh)
printf '쿠폰 %s 생성. 사용자 %s명이 진입 후 상태를 폴링하고 발급한다.\n' "$coupon_id" "$USERS"

k6 run \
  -e COUPON_ID="$coupon_id" \
  -e BASE_URL="$BASE" \
  -e USERS="$USERS" \
  -e POLL_INTERVAL_SECONDS="$POLL_INTERVAL_SECONDS" \
  -e POLL_JITTER_SECONDS="$POLL_JITTER_SECONDS" \
  -e MAX_WAIT_SECONDS="$MAX_WAIT_SECONDS" \
  scripts/load/part-6/waiting_room_journey.js

printf '\n\033[0;37mjourney_status_polls가 폴링으로 추가된 요청 수다.\n'
printf 'journey_polls_per_user와 journey_waiting_time으로 사용자 경험을 함께 확인한다.\033[0m\n'
