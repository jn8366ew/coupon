package com.example.coupon.application

import com.example.coupon.infrastructure.cache.SoldOutProperties
import com.example.coupon.infrastructure.cache.SoldOutRedisRepository
import com.github.benmanes.caffeine.cache.Caffeine
import com.github.benmanes.caffeine.cache.LoadingCache
import org.springframework.stereotype.Component
import java.time.Duration

@Component
class SoldOutState (
    private val soldOutRedisRepository: SoldOutRedisRepository,
    private val cacheMetrics: CacheMetrics,
    properties: SoldOutProperties
){

    private val soldOutCache: LoadingCache<Long, Boolean> = Caffeine.newBuilder()
        .expireAfterWrite(Duration.ofMillis(properties.fastPathTtlMs))
        .maximumSize(MAX_TRACKED_COUPONS)
        .build { couponId ->
            cacheMetrics.incrementSoldOutRedisExists()
            soldOutRedisRepository.isFlagged(couponId)
        }

    fun isSoldOut(couponId: Long): Boolean {
        val soldOut = soldOutCache.get(couponId) ?: false
        if (soldOut) cacheMetrics.incrementSoldOutFastPathHits()
        return soldOut
    }

    private companion object {
        const val MAX_TRACKED_COUPONS = 1_000L
    }
}