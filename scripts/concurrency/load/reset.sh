#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

printf '\n\033[1;36m===== coupon, issuance 데이터 리셋 =====\033[0m\n'
mysql_exec() {
  docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e "$1"
}

if [[ "$(mysql_exec "SELECT COUNT(*) FROM information_schema.tables
                      WHERE table_schema='coupon' AND table_name='issuance_dlt_log'")" == "1" ]]; then
  mysql_exec "TRUNCATE TABLE issuance_dlt_log"
fi

docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -t coupon -e "
  SET FOREIGN_KEY_CHECKS=0; TRUNCATE issuance; TRUNCATE coupon; SET FOREIGN_KEY_CHECKS=1;
  SELECT (SELECT COUNT(*) FROM coupon)   AS coupon_rows,
         (SELECT COUNT(*) FROM issuance) AS issuance_rows;
"

printf '\n\033[1;36m===== redis 데이터 리셋 (FLUSHDB) =====\033[0m\n'
docker compose exec -T redis redis-cli FLUSHDB