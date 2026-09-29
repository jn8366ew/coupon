-- KEYS: cache, lock / ARGV: lockToken, lockTtlMs
-- 반환: HIT | LOAD | WAIT

local cached = redis.call('GET', KEYS[1])
if cached then return {'HIT', cached} end

-- REDIS SET 명령어에 NX -> 해당 키가 없을떄 SET, PX는 유효기간 - TTL을 붙혀서 키를 저장함
local acquired = redis.call('SET', KEYS[2], ARGV[1], 'NX', 'PX', ARGV[2])
if acquired then return {'LOAD', ''} end
return {'WAIT', ''}