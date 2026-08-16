package com.example.coupon.application

import com.example.coupon.domain.Coupon
import java.time.LocalDateTime

class CouponIssuePolicy (
    val startsAt: LocalDateTime?,
    val validityDays: Int,
) {
    fun isBookingOpen(now: LocalDateTime): Boolean =
        startsAt?.let { !now.isBefore(it)} ?: true

    companion object {
        fun from(coupon: Coupon): CouponIssuePolicy = CouponIssuePolicy(
            startsAt=coupon.startsAt,
            validityDays = coupon.validityDays,
        )
    }
}