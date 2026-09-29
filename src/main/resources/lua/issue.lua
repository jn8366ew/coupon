-- KEYS: stock, users (set), sold_out, reconcile_index (zset)
-- ARGV: userId, soldOutTtlSeconds, issuedAtMs, couponId
-- 반환: 1=성공, 0=매진, -1=중복발급
--  -1   이미 발급된 사용자

if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then
  return -1
end

local remaining = tonumber(redis.call('GET', KEYS[1]) or '0')
if remaining <= 0 then
  return 0
end

redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
-- 대사 sliding window 인덱스: 쿠폰별 최신 발급 시각을 score로 (member는 couponId, ZADD)
redis.call('ZADD', KEYS[4], ARGV[3], ARGV[4])

if remaining == 1 then
    redis.call('SET', KEYS[3], '1', 'EX', ARGV[2])
end

return 1
