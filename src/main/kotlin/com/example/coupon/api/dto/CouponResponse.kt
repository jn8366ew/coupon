package com.example.coupon.api.dto

import com.example.coupon.domain.Coupon
import java.time.LocalDateTime

// issuedQuantity, createdAt을 잠시 삭제함
// 이유는 추후에 캐시에 저장된 값만 조회해서 바로 리턴하기 위함
// 캐시에 저장하려는 정보 5가지만...

class CouponResponse (
    val id: Long,
    val name: String,
    val totalQuantity: Int,
//    val issuedQuantity: Int,
    val validityDays: Int,
    val startsAt: LocalDateTime?,
//    val createdAt: LocalDateTime,
) {
    companion object {
        fun from(coupon: Coupon): CouponResponse = CouponResponse(
            id = requireNotNull(coupon.id),
            name = coupon.name,
            totalQuantity = coupon.totalQuantity,
//            issuedQuantity = coupon.issuedQuantity,
            validityDays = coupon.validityDays,
            startsAt = coupon.startsAt,
//            createdAt = coupon.createdAt,
        )
    }
}