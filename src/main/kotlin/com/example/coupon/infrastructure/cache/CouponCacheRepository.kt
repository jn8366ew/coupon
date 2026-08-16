package com.example.coupon.infrastructure.cache

import com.example.coupon.application.CacheMetrics
import com.example.coupon.application.CouponPolicy
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.stereotype.Repository
import tools.jackson.databind.ObjectMapper
import java.time.Duration

@Repository
class CouponCacheRepository(
    private val redis: StringRedisTemplate,
    private val mapper: ObjectMapper,
    private val properties: CacheProperties,
    private val cacheMetrics: CacheMetrics,
) {

    fun getIssuePolicyOrLoad(id: Long, loader: () -> CouponPolicy) =
        getOrLoad(
            key = "coupon:$id:issue-policy",
            loader = loader,
        )

    private fun getOrLoad(
        key: String,
        loader: () -> CouponPolicy,
    ): CouponPolicy {
        redis.opsForValue().get(key)?.let { cached ->
            cacheMetrics.incrementCouponCacheHit()
            return mapper.readValue(cached, CouponPolicy::class.java)
        }
        cacheMetrics.incrementCouponDbRead()
        val response = loader()
        redis.opsForValue().set(key, mapper.writeValueAsString(response), Duration.ofMillis(properties.ttlMs))
        return response
    }
}
