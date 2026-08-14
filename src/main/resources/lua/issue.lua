-- 발급 자격 판정 전체를 한 덩어리로 처리한다.
--
-- KEYS[1] = coupon:{id}:stock   재고 카운터 (String)
-- KEYS[2] = coupon:{id}:issued  이미 받은 userId 집합 (Set)
-- ARGV[1] = userId
--
-- 반환: 1 = 발급 허용, 0 = 매진, -1 = 이미 발급받음
--
-- 이 네 연산(SISMEMBER → GET → DECR → SADD)이 원자적이어야 하는 것이 Lua 를 쓰는 이유다.
-- 애플리케이션에서 나눠 호출하면 왕복 사이에 다른 요청이 끼어들어
-- 같은 사용자에게 두 장이 나가거나 재고가 음수가 된다.
-- 명령이 하나뿐이었다면(DECR) Redis 가 이미 원자적이므로 Lua 가 필요 없다.
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then
    return -1
end

local remaining = tonumber(redis.call('GET', KEYS[1]) or '0')
if remaining <= 0 then
    return 0
end

redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
return 1
