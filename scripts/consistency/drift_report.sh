#!/usr/bin/env bash
set -euo pipefail
COUPON_ID="${COUPON_ID:?COUPON_ID 환경변수 필요}"
cd "$(dirname "$0")/../../.."

mysql_scalar() { docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e "$1"; }
redis_cli()    { docker compose exec -T redis redis-cli "$@"; }

if [[ "$(mysql_scalar "SELECT COUNT(*) FROM coupon WHERE id=$COUPON_ID")" != "1" ]]; then
  printf '쿠폰 %s가 없습니다.\n' "$COUPON_ID" >&2
  exit 1
fi

total="$(mysql_scalar "SELECT total_quantity FROM coupon WHERE id=$COUPON_ID")"
issued="$(mysql_scalar "SELECT issued_quantity FROM coupon WHERE id=$COUPON_ID")"
issued_rows="$(mysql_scalar "SELECT COUNT(*) FROM issuance WHERE coupon_id=$COUPON_ID AND status='ISSUED'")"
stock="$(redis_cli GET "coupon:$COUPON_ID:stock")"; stock="${stock:-0}"
users="$(redis_cli SCARD "coupon:$COUPON_ID:users")"
sold_out="$(redis_cli EXISTS "coupon:$COUPON_ID:sold_out")"

db_gap=$((total - issued - stock))
list_gap=$((total - users - stock))

printf '\n\033[1;36m===== 쿠폰 %s 상태 =====\033[0m\n' "$COUPON_ID"
printf '  총 수량          : %s\n' "$total"
printf '  DB 발급 수       : %s (ISSUED %s)\n' "$issued" "$issued_rows"
printf '  Redis 잔여 재고  : %s\n' "$stock"
printf '  Redis 사용자 수  : %s\n' "$users"
printf '  매진 표시        : %s\n' "$sold_out"
printf '  DB 불일치        : %s\n' "$db_gap"
printf '  사용자 불일치    : %s\n' "$list_gap"

if (( db_gap == 0 && list_gap == 0 )); then
  printf '\033[1;32m  => 정상\033[0m\n'
elif (( db_gap > 0 && list_gap == 0 )); then
  printf '\033[1;33m  => DB 저장 실패: DLT 재처리 대상\033[0m\n'
elif (( db_gap == 0 && list_gap > 0 )); then
  printf '\033[1;33m  => Redis users 누락: 대사 자동 보정 대상\033[0m\n'
else
  printf '\033[1;31m  => 자동 보정하지 않고 확인이 필요한 상태\033[0m\n'
fi