package com.example.coupon.application

import com.example.coupon.api.dto.CreateCouponRequest
import com.example.coupon.domain.Coupon
import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.domain.IssuanceRepository
import com.example.coupon.domain.IssuanceStatus
import com.example.coupon.support.AlreadyIssuedException
import com.example.coupon.support.CouponNotFoundException
import com.example.coupon.support.ExpiredException
import com.example.coupon.support.IssuanceNotFoundException
import com.example.coupon.support.NotStartedException
import com.example.coupon.support.SoldOutException
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime


@Service
class IssuanceService(
    private val couponRepository: CouponRepository,
    private val issuanceRepository: IssuanceRepository,
) {
    @Transactional
    fun use(issuanceId: Long, userId: Long): Issuance {
        val issuance = issuanceRepository.findById(issuanceId)
            .orElseThrow { IssuanceNotFoundException() }

        when (issuance.status) {
            IssuanceStatus.USED -> throw AlreadyIssuedException()
            IssuanceStatus.EXPIRED -> throw ExpiredException()
            IssuanceStatus.ISSUED -> Unit
        }

        val now = LocalDateTime.now()
        if (issuance.isExpired(now)) {
            throw ExpiredException()
        }

        issuance.markUsed(now)
        return issuance
    }

    fun findByUser(userId: Long): List<Issuance> =
        issuanceRepository.findByUserIdOrderByIssuedAtDesc(userId)
}