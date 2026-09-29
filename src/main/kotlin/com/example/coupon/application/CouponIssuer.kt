package com.example.coupon.application

import com.example.coupon.infrastructure.cache.IssuanceRedisRepository
import com.example.coupon.support.AlreadyIssuedException
import com.example.coupon.support.SoldOutException
import org.springframework.stereotype.Component

enum class IssueResult {
    OK,
    SOLD_OUT,
    DUPLICATE,
}

@Component
class CouponIssuer (
    private val issuanceRedisRepository: IssuanceRedisRepository,
) {

    fun tryIssue(couponId: Long, userId: Long) {
        when (issuanceRedisRepository.tryIssue(couponId, userId)) {
            1L -> Unit
            0L -> throw SoldOutException()
            -1L -> throw AlreadyIssuedException()
            else -> error("예상치 못한 Lua 결과")
        }
    }

    fun initStock(couponId: Long, totalQuantity: Int) {
        issuanceRedisRepository.initStock(couponId, totalQuantity)
    }

    fun remainingStock(couponId: Long): Long? =
        issuanceRedisRepository.remainingStock(couponId)
}
