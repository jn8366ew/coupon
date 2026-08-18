-- KEYS: queue (sorted set), pass (이 사용자의 입장권 키)
-- ARGV: userId
-- 반환: {status, position}  status 1=통과, 0=대기. position 은 1-based 순번(통과면 0).

if redis.call('EXISTS', KEYS[2]) == 1 then
  return {'1', '0'}
end

-- score = 들어온 시각. Redis TIME 이라 서버가 여러 대여도 단일 시계로 FIFO 보장.
local t = redis.call('TIME')
local score = tonumber(t[1]) * 1000000 + tonumber(t[2])
-- NX: 이미 줄에 있으면 그대로 두어 새로고침해도 순번이 안 밀린다.
redis.call('ZADD', KEYS[1], 'NX', score, ARGV[1])

local rank = redis.call('ZRANK', KEYS[1], ARGV[1])
return {'0', tostring(rank + 1)}
