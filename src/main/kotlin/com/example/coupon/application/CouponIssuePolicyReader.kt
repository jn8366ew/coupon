package com.example.coupon.application

import com.example.coupon.domain.CouponRepository
import com.example.coupon.infrastructure.cache.CacheProperties
import com.example.coupon.infrastructure.cache.CouponCacheRepository
import com.example.coupon.support.CouponNotFoundException
import org.springframework.stereotype.Service

@Service
class CouponIssuePolicyReader(
    private val couponRepository: CouponRepository,
    private val couponCacheRepository: CouponCacheRepository,
    private val cacheProperties: CacheProperties,
) {
    fun get(couponId: Long): CouponPolicy = couponCacheRepository.getIssuePolicyOrLoad(couponId) {
        Thread.sleep(cacheProperties.simulatedLoadLatencyMs)
        couponRepository.findById(couponId)
            .orElseThrow { CouponNotFoundException() }
            .let(CouponPolicy::from)
    }
}