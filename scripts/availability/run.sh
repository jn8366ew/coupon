#!/usr/bin/env bash
# 현재 소스 단계 자동 실행. 직접 선택: baseline | single | scale | verify | journey | gateway
set -euo pipefail
cd "$(dirname "$0")/../../.."

BASE="${BASE_URL:-http://localhost:8080}"
RATE="${RATE:-1000}"
DURATION="${DURATION:-20s}"
QUANTITY="${QUANTITY:-1000000}"

create_coupon() {
  BASE_URL="$1" QUANTITY="$QUANTITY" ./scripts/load/create_coupon.sh
}

require_source() {
  local path="$1"
  local stage="$2"
  [[ -f "$path" ]] || { printf '%s 이후에 실행할 수 있다\n' "$stage" >&2; exit 1; }
}

baseline() {
  printf '\n\033[1;36m===== part-6-0: 대기실 없는 발급 트래픽 급증 =====\033[0m\n'
  wait_ready "$BASE"
  ./scripts/load/reset.sh >/dev/null
  local coupon_id; coupon_id=$(create_coupon "$BASE")
  k6 run -e COUPON_ID="$coupon_id" -e BASE_URL="$BASE" -e RATE="$RATE" -e DURATION="$DURATION" \
    scripts/load/part-6/issue_flood.js
  printf '\033[0;37mk6의 http_reqs가 대기실 없이 발급 API에 도착한 요청 수다.\033[0m\n'
}

wait_ready() {
  for _ in $(seq 1 60); do
    curl -fsS "$1/api/users/me/issuances" -H 'X-User-Id: 1' >/dev/null 2>&1 && return
    sleep 1
  done
  printf '%s 준비 실패\n' "$1" >&2
  return 1
}

pass_count() {
  docker compose exec -T redis redis-cli --raw --scan --pattern "waiting:{$1}:pass:*" |
    awk 'NF { count++ } END { print count + 0 }'
}

waiting_room() {
  local mode="$1"
  local admit_per_second="${COUPON_WAITING_ROOM_ADMIT_PER_SECOND:-100}"
  local pass_ttl_ms="${COUPON_WAITING_ROOM_PASS_TTL_MS:-30000}"
  local tolerance_percent="${TOLERANCE_PERCENT:-30}"
  local secondary="${SECONDARY_BASE_URL:-http://localhost:8081}"

  [[ "$DURATION" =~ ^[1-9][0-9]*s$ ]] || { echo "DURATION은 20s처럼 초 단위로 입력해야 한다" >&2; exit 1; }
  local seconds="${DURATION%s}"
  (( RATE > admit_per_second )) || { echo "RATE는 통과 속도(${admit_per_second}/s)보다 커야 한다" >&2; exit 1; }
  (( seconds * 1000 < pass_ttl_ms )) || { echo "DURATION은 입장권 TTL보다 짧아야 한다" >&2; exit 1; }
  wait_ready "$BASE"

  local bases="$BASE"
  local servers=1
  if [[ "$mode" == "scale" ]]; then
    trap 'docker compose --profile scale stop coupon-service-2 >/dev/null 2>&1 || true' EXIT
    docker compose --profile scale up -d coupon-service-2 >/dev/null
    wait_ready "$secondary"
    bases="$BASE,$secondary"
    servers=2
  else
    docker compose --profile scale stop coupon-service-2 >/dev/null
  fi

  printf '\n\033[1;36m===== part-6-1: 서버 %s대의 전역 통과 속도 =====\033[0m\n' "$servers"
  ./scripts/load/reset.sh >/dev/null
  local coupon_id; coupon_id=$(create_coupon "$BASE")
  k6 run -e COUPON_ID="$coupon_id" -e BASES="$bases" -e RATE="$RATE" -e DURATION="$DURATION" \
    scripts/load/part-6/waiting_room_flood.js

  local admitted; admitted=$(pass_count "$coupon_id")
  local measured_rate=$(( admitted / seconds ))
  local lower_bound=$(( admit_per_second * (100 - tolerance_percent) / 100 ))
  local upper_bound=$(( admit_per_second * (100 + tolerance_percent) / 100 ))
  printf 'Redis 입장권: %s건, 약 %s건/s\n' "$admitted" "$measured_rate"
  (( measured_rate >= lower_bound && measured_rate <= upper_bound )) || {
    printf '✗ 실패: 기대 %s건/s, 허용 범위 %s~%s건/s\n' "$admit_per_second" "$lower_bound" "$upper_bound" >&2
    return 1
  }
  printf '✓ 통과: 서버 수와 관계없이 전역 통과 속도 유지\n'
}

source_stage() {
  if [[ -f gateway/src/main/kotlin/com/apiece/gateway/GatewayApplication.kt ]]; then
    printf 'gateway'
  elif [[ -f src/main/kotlin/com/apiece/coupon/application/RedisWaitingRoom.kt ]]; then
    printf 'single'
  else
    printf 'baseline'
  fi
}

MODE="${1:-$(source_stage)}"
case "$MODE" in
  baseline) baseline ;;
  single|scale)
    require_source src/main/kotlin/com/apiece/coupon/application/RedisWaitingRoom.kt part-6-1-waiting-room
    waiting_room "$MODE"
    ;;
  verify)
    require_source src/main/kotlin/com/apiece/coupon/application/RedisWaitingRoom.kt part-6-1-waiting-room
    ./scripts/load/part-6/verify.sh
    ;;
  journey)
    require_source src/main/kotlin/com/apiece/coupon/application/RedisWaitingRoom.kt part-6-1-waiting-room
    ./scripts/load/part-6/waiting_room_journey.sh
    ;;
  gateway)
    require_source gateway/src/main/kotlin/com/apiece/gateway/GatewayApplication.kt part-6-2-edge-rate-limit
    ./scripts/load/part-6/gateway_rate_limit.sh
    ;;
  *) echo "사용법: run.sh [baseline|single|scale|verify|journey|gateway]" >&2; exit 1 ;;
esac
