#!/usr/bin/env bash
# part-6-1 Redis 대기실 검증: 순서 보장, 진입 멱등성, 통과 후 발급, 게이트.
# 사전: docker compose 스택 + coupon-service(part-6-1 이미지)가 떠 있어야 한다.
set -euo pipefail
cd "$(dirname "$0")/../../.."

BASE="${BASE_URL:-http://localhost:8080}"
QUANTITY="${QUANTITY:-1000000}"

[[ -f src/main/kotlin/com/apiece/coupon/application/RedisWaitingRoom.kt ]] || {
  echo "verify는 part-6-1-waiting-room 이후에 실행할 수 있다" >&2
  exit 1
}

fail=0
pass()  { printf '\033[1;32m  ✓ 통과\033[0m %s\n' "$1"; }
ng()    { printf '\033[1;31m  ✗ 실패\033[0m %s\n' "$1"; fail=1; }
check() { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else ng "$1 (실제 $2, 기대 $3)"; fi; }

enter() { curl -fsS -X POST "$BASE/api/waiting-room/$1" -H "X-User-Id: $2"; }
status() { curl -fsS "$BASE/api/waiting-room/$1" -H "X-User-Id: $2"; }
issue_code() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/coupons/$1/issue" -H "X-User-Id: $2"; }
wait_until_admitted() {
  for _ in $(seq 1 20); do
    if [[ "$(status "$1" "$2" | jq -r '.admitted')" == "true" ]]; then
      echo true
      return
    fi
    sleep 0.25
  done
  echo false
}
printf '\n\033[1;36m===== part-6-1 Redis 대기실 검증 =====\033[0m\n'
./scripts/load/reset.sh >/dev/null
coupon=$(BASE_URL="$BASE" QUANTITY="$QUANTITY" ./scripts/load/create_coupon.sh)
printf '쿠폰 %s 생성\n' "$coupon"

printf '\n[순서 보장] 먼저 온 사람이 앞 순번\n'
check "user 1 순번" "$(enter "$coupon" 1 | jq -r '.position')" "1"
check "user 2 순번" "$(enter "$coupon" 2 | jq -r '.position')" "2"
check "user 3 순번" "$(enter "$coupon" 3 | jq -r '.position')" "3"

printf '\n[진입 멱등성] 새로고침해도 순번 안 밀림\n'
check "user 1 재진입 순번" "$(enter "$coupon" 1 | jq -r '.position')" "1"
check "user 2 상태 조회 순번" "$(status "$coupon" 2 | jq -r '.position')" "2"

printf '\n[상태 조회] 드레인 전후에도 조회는 재등록하지 않음\n'
check "user 1 통과 여부" "$(wait_until_admitted "$coupon" 1)" "true"

printf '\n[통과 후 발급] 드레인(매초)으로 통과 -> 입장권 -> 발급 성공\n'
check "user 1 발급 응답" "$(issue_code "$coupon" 1)" "200"

printf '\n[게이트] 대기실 안 거친 사용자는 발급 차단 (403)\n'
check "입장권 없는 발급" "$(issue_code "$coupon" 99999)" "403"

if (( fail == 0 )); then
  printf '\n\033[1;32m===== 모두 통과 =====\033[0m\n'
else
  printf '\n\033[1;31m===== 실패한 항목이 있습니다 =====\033[0m\n'; exit 1
fi
