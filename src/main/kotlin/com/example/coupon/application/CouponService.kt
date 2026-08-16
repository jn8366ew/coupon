package com.example.coupon.application

import com.example.coupon.api.dto.CreateCouponRequest
import com.example.coupon.domain.Coupon
import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.infrastructure.cache.CacheProperties
import com.example.coupon.infrastructure.messaging.IssuanceRequestProducer
import com.example.coupon.infrastructure.messaging.IssuanceRequested
import com.example.coupon.support.CouponNotFoundException
import com.example.coupon.support.IssuanceAcceptFailedException
import com.example.coupon.support.NotStartedException
import com.example.coupon.support.SoldOutException
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

private val log = KotlinLogging.logger {}

@Service
class CouponService(
    private val couponRepository: CouponRepository,
    private val couponIssuePolicyReader: CouponIssuePolicyReader,
    private val couponIssuer: CouponIssuer,
    private val issuanceRequestProducer: IssuanceRequestProducer,
    private val soldOutState: SoldOutState,
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

    fun issue(couponId: Long, userId: Long): Issuance {
        if (soldOutState.isSoldOut(couponId)) {
            throw SoldOutException()
        }

        val policy = couponIssuePolicyReader.get(couponId)

        val now = LocalDateTime.now()
        if (!policy.isBookingOpen(now)) {
            throw NotStartedException()
        }

        couponIssuer.tryIssue(couponId, userId)

        val expiresAt = now.plusDays(policy.validityDays.toLong())
        val event = IssuanceRequested(
            couponId = couponId,
            userId = userId,
            issueAt = now,
            expiresAt = expiresAt,
        )

        // 발행에 실패하면 그 한 장은 아무에게도 가지 않은 채 사라진다(과소발급).
        // 4-4 에서 보상(restore)을 걷어냈으므로 되돌리지 않는다 — 재고는 깎인 채로 남고
        // 그 사용자는 :users 에 남아 다시 시도해도 거절된다. 의도된 선택이고,
        // 그 대신 매진 플래그가 실제 재고와 어긋나지 않는다 (docs/architecture.md 4).
        // DB 안에는 모순이 없어 verify 의 세 판정은 전부 OK 로 통과하므로 로그가 유일한 흔적이다.
        try {
            issuanceRequestProducer.publish(event)
                // 콜백은 프로듀서 I/O 스레드에서 돈다. 요청 스레드를 잡지 않는다.
                .whenComplete { _, error ->
                    if (error != null) log.error(error) {
                        "$PHASE 실패 — 재고가 깎인 채로 남는다: couponId=$couponId, userId=$userId"
                    }
                }
        }
        catch (e: Exception) {
            // send 가 즉시 던지는 경우 (직렬화 실패, 메타데이터 대기 초과 = max.block.ms).
            // 재시도해도 이 사용자는 :users 에 남아 있어 거절된다 — 그럼에도 서버 쪽 사정이므로 503 이다.
            log.error(e) { "$PHASE 실패 — 재고가 깎인 채로 남는다: couponId=$couponId, userId=$userId" }
            throw IssuanceAcceptFailedException()
        }

        return Issuance(
            userId = userId,
            couponId = couponId,
            issuedAt = now,
            expiresAt = expiresAt,
        )
    }

    companion object {
        private const val PHASE = "발급 요청 발행"
    }
}
