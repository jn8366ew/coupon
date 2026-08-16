package com.example.coupon.infrastructure.cache

import com.example.coupon.application.CacheMetrics
import com.example.coupon.application.CouponIssuePolicy
import io.github.oshai.kotlinlogging.KotlinLogging
import jakarta.annotation.PreDestroy
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.stereotype.Repository
import tools.jackson.databind.ObjectMapper
import java.time.Duration
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors

private val log = KotlinLogging.logger {}


@Repository
class CouponCacheRepository(
    private val redis: StringRedisTemplate,
    private val mapper: ObjectMapper,
    private val properties: CacheProperties,
    private val cacheMetrics: CacheMetrics,
) {
    private val backgroundExecutor = Executors.newFixedThreadPool(4) { r ->
        Thread(r, "coupon-cache-swr-refresh").apply { isDaemon = true }
    }
    private val lookupScript = listLuaScript("lua/cache-single-flight-swr.lua")
    private val releaseLockScript = longLuaScript("lua/release-lock.lua")

    fun getIssuePolicyOrLoad(id: Long, loader: () -> CouponIssuePolicy) =
        getOrLoad(
            cacheKey = "coupon:$id:issue-policy",
            lockKey = "coupon:$id:issue-policy:lock",
            loader = loader,
        )

    private fun getOrLoad(
        cacheKey: String,
        lockKey: String,
        loader: () -> CouponIssuePolicy,
    ): CouponIssuePolicy {
        val token = UUID.randomUUID().toString()
        repeat(MAX_RETRIES) {
            // KEYS 에는 실제 키만 넣는다 (Lua 헤더 주석의 계약: KEYS = cache, lock).
            // token 은 값이므로 ARGV 다. 단일 Redis 에서는 KEYS 에 섞여 있어도 그냥 안 쓰여서
            // 동작하지만, 클러스터는 KEYS 로 슬롯을 계산하므로 키가 아닌 값이 섞이면 깨진다.
            val now = Instant.now().toEpochMilli()
            val result = redis.runForStrings(
                lookupScript,
                listOf(cacheKey, lockKey),
                now, properties.freshMs, token, LOCK_TTL_MS,
            )

            when (result[0]) {
                "HIT" -> {
                    cacheMetrics.incrementCouponCacheHit()
                    return mapper.readValue(result[1], CouponIssuePolicy::class.java)
                }
                "STALE_REFRESH" -> {
                    cacheMetrics.incrementCouponCacheHit()
                    backgroundExecutor.execute {
                        try {
                            fillCache(cacheKey, lockKey, token, loader)
                        } catch (e: Exception) {
                            log.warn {"백그라운드 SWR 갱신 실패 (key=$cacheKey, lockKey=$lockKey, ${e.message})"}
                        }
                    }
                    return mapper.readValue(result[1], CouponIssuePolicy::class.java)
                }
                "LOAD" -> return fillCache(cacheKey, lockKey, token, loader)

                "WAIT" -> Thread.sleep(WAIT_BACKOFF_MS)

            }
        }
        throw IllegalStateException("쿠폰 캐시 채우기 Timeout (key=$cacheKey")
    }

    private fun fillCache(
        cacheKey: String,
        lockKey: String,
        token: String,
        loader: () -> CouponIssuePolicy,
    ): CouponIssuePolicy {
        try {
            cacheMetrics.incrementCouponDbRead()
            val response = loader()
            redis.opsForHash<String, String>().putAll(
                cacheKey,
                mapOf(
                    "value" to mapper.writeValueAsString(response),
                    "fetchedAtMs" to Instant.now().toEpochMilli().toString(),
                )
            )
            redis.expire(cacheKey, Duration.ofMillis(properties.ttlMs))
            return response
        } finally {
            redis.runForLong(
                releaseLockScript,
                listOf(lockKey),
                token,
            )
        }
    }

    @PreDestroy
    fun shutdown() {
        backgroundExecutor.shutdown()
    }


    private companion object {
        const val MAX_RETRIES = 50
        const val WAIT_BACKOFF_MS = 20L
        const val LOCK_TTL_MS = 3_000L
    }
}
