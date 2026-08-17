#!/usr/bin/env bash
BASE="${BASE_URL:-http://localhost:8080}"

mysql_scalar() { docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e "$1"; }
redis_cli()    { docker compose exec -T redis redis-cli "$@"; }

wait_service_ready() {
  for _ in $(seq 1 60); do
    curl -fsS "$BASE/metrics/cache" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

restart_service() {
  docker compose up -d --force-recreate kafka >/dev/null 2>&1
  for _ in $(seq 1 40); do
    [[ "$(docker compose ps kafka --format '{{.Status}}' 2>/dev/null || true)" == *healthy* ]] && break
    sleep 1
  done
  if [[ -n "${1:-}" ]]; then
    COUPON_RECONCILE_INTERVAL_MS="$1" docker compose up -d --force-recreate coupon-service >/dev/null
  else
    docker compose restart coupon-service >/dev/null
  fi
  wait_service_ready || { printf 'coupon-service 재기동 실패\n' >&2; exit 1; }
}

fail=0
pass()  { printf '\033[1;32m  ✓ 통과\033[0m %s\n' "$1"; }
ng()    { printf '\033[1;31m  ✗ 실패\033[0m %s\n' "$1"; fail=1; }
check() { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else ng "$1 (실제 $2, 기대 $3)"; fi; }

summary() {
  if (( fail == 0 )); then
    printf '\n\033[1;32m===== %s 검증: 모두 통과 =====\033[0m\n' "$1"
  else
    printf '\n\033[1;31m===== %s 검증: 실패 =====\033[0m\n' "$1"
    exit 1
  fi
}