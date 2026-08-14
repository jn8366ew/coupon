package com.example.coupon.application

import com.example.coupon.api.dto.CreateCouponRequest
import com.example.coupon.domain.Coupon
import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.infrastructure.messaging.IssuanceRequestProducer
import com.example.coupon.infrastructure.messaging.IssuanceRequested
import com.example.coupon.support.CouponNotFoundException
import com.example.coupon.support.NotStartedException
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

private val log = KotlinLogging.logger {}


@Service
class CouponService(
    private val couponRepository: CouponRepository,
    private val couponIssuer: CouponIssuer,
    private val issuanceRequestProducer: IssuanceRequestProducer
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

    @Transactional
    fun issue(couponId: Long, userId: Long): Issuance {
        val coupon = couponRepository.findById(couponId)
            .orElseThrow { CouponNotFoundException() }

        val now = LocalDateTime.now()
        if (!coupon.isBookingOpen(now)) {
            throw NotStartedException()
        }

        couponIssuer.tryIssue(couponId, userId)

        val expiresAt = now.plusDays(coupon.validityDays.toLong())
        val event = IssuanceRequested(
            couponId = couponId,
            userId = userId,
            issueAt = now,
            expiresAt = expiresAt,
        )

        // 여기서부터가 보상 구간이다. tryIssue 가 Redis 재고를 이미 깎았으므로,
        // 큐에 넣지 못하면 그 한 장은 아무에게도 가지 않은 채 사라진다(과소발급).
        // DB 안에는 모순이 없어 verify 의 세 판정은 전부 OK 로 통과한다 — 12.2 와 같은 실패 모드다.
        try {
            issuanceRequestProducer.publish(event)
                // 콜백은 프로듀서 I/O 스레드에서 돈다. 요청 스레드를 잡지 않고,
                // Redis 만 건드리므로 이 트랜잭션이 끝난 뒤에 실행돼도 상관없다.
                .whenComplete { _, error -> if (error != null) compensate(couponId, userId, error) }
        }
        catch (e: Exception) {
            // send 가 즉시 던지는 경우 (직렬화 실패, 메타데이터 대기 초과 = max.block.ms).
            // 되돌린 뒤 다시 던진다 — 사용자는 500 을 받고 재고는 보존된다.
            compensate(couponId, userId, e)
            throw e
        }

        return Issuance(
            userId = userId,
            couponId = couponId,
            issuedAt = now,
            expiresAt = expiresAt,
        )
    }

    /**
     * 큐에 넣지 못했으니 발급 자격을 되돌린다.
     *
     * 보상 자체가 실패하는 경우까지는 막지 못한다 (Redis 가 죽어 있으면 되돌릴 수단이 없다).
     * 그때는 로그가 유일한 흔적이므로 ERROR 로 남긴다.
     */
    private fun compensate(couponId: Long, userId: Long, cause: Throwable) {
        try {
            val restored = couponIssuer.restore(couponId, userId)
            log.error(cause) {
                "발급 요청 발행 실패 — 재고 보상 ${if (restored) "완료" else "불필요(이미 되돌아감)"}: " +
                    "couponId=$couponId, userId=$userId"
            }
        }
        catch (e: Exception) {
            log.error(e) { "발급 요청 발행 실패 후 재고 보상마저 실패: couponId=$couponId, userId=$userId" }
        }
    }
}
