package com.example.coupon.application

import com.example.coupon.api.dto.CreateCouponRequest
import com.example.coupon.domain.Coupon
import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.support.AlreadyIssuedException
import com.example.coupon.support.SoldOutException
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional


@Service
class CouponService(
    private val couponRepository: CouponRepository,
    private val couponIssuer: CouponIssuer,
    private val issuanceWriter: IssuanceWriter,
) {
    @Transactional
    fun createCoupon(request: CreateCouponRequest): Coupon {
        val coupon = couponRepository.save(
            Coupon(
                name = request.name,
                totalQuantity = request.totalQuantity,
                validityDays = request.validityDays,
                startsAt = request.startsAt,
            )
        )
        couponIssuer.initStock(coupon.id!!, coupon.totalQuantity)
        return coupon
    }

    /**
     * 선착순 발급.
     *
     * 트랜잭션은 이 메서드에 걸려 있지 않다. 발급 자격 판정을 Redis 가 원자적으로 끝내고,
     * 통과한 요청만 DB 로 내려보내기 위해서다. 매진·중복으로 거절되는 요청 —
     * 부하가 걸리면 대부분이 그렇다 — 은 DB 커넥션조차 잡지 않는다.
     */
    fun issue(couponId: Long, userId: Long): Issuance {
        when (couponIssuer.tryIssue(couponId, userId)) {
            IssueResult.SOLD_OUT -> throw SoldOutException()
            IssueResult.DUPLICATE -> throw AlreadyIssuedException()
            IssueResult.OK -> Unit
        }

        // 여기부터 Redis 재고는 이미 줄어 있다. Redis 는 DB 트랜잭션 밖이라
        // 아래가 롤백돼도 저절로 돌아오지 않는다. 실패하면 직접 되돌려야 한다.
        return try {
            issuanceWriter.write(couponId, userId)
        } catch (e: Exception) {
            couponIssuer.restore(couponId, userId)
            throw e
        }
    }
}
