-- KEYS[1] = lock / ARGV[1] = lockToken
-- 내 token을 가진 락만 삭제
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0