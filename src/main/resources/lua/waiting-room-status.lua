-- KEYS: queue (sorted set), pass (이 사용자의 입장권 키)
-- ARGV: userId
-- 반환: 0=통과, 1-based 순번=대기, -1=아직 진입하지 않음

if redis.call('EXISTS', KEYS[2]) == 1 then
  return 0
end

local rank = redis.call('ZRANK', KEYS[1], ARGV[1])
if not rank then
  return -1
end

return rank + 1
