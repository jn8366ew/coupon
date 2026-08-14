package com.example.coupon.infrastructure.messaging

import com.example.coupon.domain.Coupon
import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.domain.IssuanceRepository
import com.example.coupon.support.CouponNotFoundException
import com.example.coupon.support.NotStartedException
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

private val log = KotlinLogging.logger {}

@Component
class IssuanceWriter(
    private val transactional: IssuanceTransactionWriter
) {

    fun write(event: IssuanceRequested) {
        // 이렇게 한 이유는 실패로 예를 그냥 밖으로 뱉어버리면 워커가 재처리를 계속하지 않길 원함
        // 중복 발급이니까.
        try {
            transactional.insertAndIncrement(event)
        } catch (e: DataIntegrityViolationException) {
            log.debug { "UNIQUE 위반은 멱등 처리: couponId = ${event.couponId}, userId = ${event.userId}" }
        }
    }
}