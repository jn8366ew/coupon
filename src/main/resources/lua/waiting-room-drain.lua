-- KEYS: queue (sorted set)
-- ARGV: admitPerSecond(통과 속도), passTtlMs(입장권 TTL), passKeyPrefix
-- 반환: 통과시킨 인원 수.
-- 줄 앞에서 통과 속도만큼 입장권 발급. 꺼내기(ZRANGE)와 지우기(ZREM)가 한 번에 일어나 두 번 통과 방지.

local users = redis.call('ZRANGE', KEYS[1], 0, tonumber(ARGV[1]) - 1)
if #users == 0 then
  return 0
end

local ttl = tonumber(ARGV[2])
for _, userId in ipairs(users) do
  redis.call('SET', ARGV[3] .. userId, '1', 'PX', ttl)
end
redis.call('ZREM', KEYS[1], unpack(users))
return #users
