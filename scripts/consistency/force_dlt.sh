#!/usr/bin/env bash
set -euo pipefail
COUPON_ID="${COUPON_ID:?COUPON_ID 환경변수 필요}"
COUNT="${COUNT:-10}"
USER_BASE="${USER_BASE:-900000}"
TOPIC="${TOPIC:-issuance.requested.DLT}"
cd "$(dirname "$0")/../../.."

redis_cli() { docker compose exec -T redis redis-cli "$@"; }

issued_at="$(date -u +%Y-%m-%dT%H:%M:%S)"
expires_at="$(date -u -v+7d +%Y-%m-%dT%H:%M:%S)"

printf '\n\033[1;36m===== [상황 만들기] 발급은 됐는데 DB 저장이 실패한 경우 %s건 (force_dlt) =====\033[0m\n' \
  "$COUNT"

user_ids=()
for i in $(seq 1 "$COUNT"); do
  user_ids+=( $(( USER_BASE + i )) )
done

if [[ "$(redis_cli SISMEMBER "coupon:$COUPON_ID:users" "${user_ids[0]}")" == "1" ]]; then
  printf '\033[1;33m  이미 주입된 쿠폰입니다. 먼저 ./scripts/load/reset.sh 로 초기화한 뒤 다시 실행하세요.\033[0m\n'
  exit 1
fi

redis_cli DECRBY "coupon:$COUPON_ID:stock" "$COUNT" >/dev/null
redis_cli SADD "coupon:$COUPON_ID:users" "${user_ids[@]}" >/dev/null
printf '  Redis: 재고 %s 줄이고 발급자 명단에 %s명 추가 (%s~%s번)  ← 사용자에겐 발급 성공으로 보임\n' \
  "$COUNT" "$COUNT" "${user_ids[0]}" "${user_ids[$((COUNT - 1))]}"

{
  for i in "${!user_ids[@]}"; do
    printf '{"couponId":%s,"userId":%s,"issuedAt":"%s","expiresAt":"%s"}\n' \
      "$COUPON_ID" "${user_ids[$i]}" "$issued_at" "$expires_at"
  done
} | docker compose exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic "$TOPIC" >/dev/null

printf '  Kafka: DB 저장이 끝내 실패한 메시지 %s건을 DLT(실패 메시지 보관함)에 넣음\n' "$COUNT"
printf '\033[1;32m  완료: DB 에는 발급 기록이 없고 Redis 만 발급된 상태 → DB 쪽 숫자가 어긋납니다.\033[0m\n'