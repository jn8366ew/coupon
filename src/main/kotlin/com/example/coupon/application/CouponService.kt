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
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

@Service
class CouponService(
    private val couponRepository: CouponRepository,
    private val cacheProperties: CacheProperties,
    private val cacheMetrics: CacheMetrics,
    private val couponIssuer: CouponIssuer,
    private val issuanceRequestProducer: IssuanceRequestProducer,
    private val issuanceCompensator: IssuanceCompensator,
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
        cacheMetrics.incrementCouponDbRead()
        // 이걸 넣은 이유는 DB에 조회하는 응답하는 속도를 의미를 늦추기 위함
        // 로컬은 너무 빨라서 100ms 늦춰서 테스트 해보려 함.
        // DB를 조회핧때랑 캐시 조회할때랑 차이가 난다고 강의에서 이야기 함
        Thread.sleep(cacheProperties.simulatedLoadLatencyMs)
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
                .whenComplete { _, error ->
                    if (error != null) issuanceCompensator.compensate(couponId, userId, error, PHASE)
                }
        }
        catch (e: Exception) {
            // send 가 즉시 던지는 경우 (직렬화 실패, 메타데이터 대기 초과 = max.block.ms).
            // 되돌렸으므로 이 사용자는 지금 다시 시도하면 성공한다. 그래서 500 이 아니라 503 이다.
            // 원인 예외는 compensate 안에서 ERROR 로그로 남으므로 여기서 흘려보내도 잃지 않는다.
            issuanceCompensator.compensate(couponId, userId, e, PHASE)
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
