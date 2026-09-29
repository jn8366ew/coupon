package com.example.coupon.application

import org.springframework.stereotype.Component
import java.util.concurrent.atomic.AtomicLong

@Component
class CacheMetrics {
    private val couponDbReads = AtomicLong()
    private val couponCacheHits = AtomicLong()
    private val soldOutRedisExists = AtomicLong()
    private val soldOutFastPathHits = AtomicLong()

    fun incrementCouponDbRead() {
        couponDbReads.incrementAndGet();
    }

    fun incrementCouponCacheHit() {
        couponCacheHits.incrementAndGet();
    }
    fun incrementSoldOutRedisExists() {
        soldOutRedisExists.incrementAndGet();
    }
    fun incrementSoldOutFastPathHits() {
        soldOutFastPathHits.incrementAndGet();
    }
    fun snapshot(): CacheMetricsSnapshot = CacheMetricsSnapshot(
        couponDbReads = couponDbReads.get(),
        couponCacheHits = couponCacheHits.get(),
        soldOutRedisExists = soldOutRedisExists.get(),
        soldOutFastPathHits = soldOutFastPathHits.get(),
    )

    fun reset() {
        couponDbReads.set(0)
        couponCacheHits.set(0)
        soldOutRedisExists.set(0)
        soldOutFastPathHits.set(0)
    }
}

class CacheMetricsSnapshot(
    val couponDbReads: Long,
    val couponCacheHits: Long,
    val soldOutRedisExists: Long,
    val soldOutFastPathHits: Long,
)