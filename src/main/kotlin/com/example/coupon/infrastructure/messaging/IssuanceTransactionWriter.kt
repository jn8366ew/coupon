package com.example.coupon.infrastructure.messaging

import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.domain.IssuanceRepository
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional

/**
 * 워커의 실제 @Transactional 경계. INSERT 하나뿐이다.
 *
 * 예전에는 여기서 couponRepository.incrementIssueQuantity 도 같이 쳤다. 그런데 그 열은
 * IssuedQuantitySynchronizer 가 1초마다 Redis 재고에서 계산해 통째로 덮어쓰므로 워커의 +1 은
 * 결과에 기여하지 않았고, 선착순이라 모든 발급이 coupon 단일 행을 향하는 탓에 컨슈머들을
 * 그 행 락에 줄 세우기만 했다 (docs/load-test-k6.md 14.6).
 */
@Component
class IssuanceTransactionWriter(
    private val issuanceRepository: IssuanceRepository,
    private val couponRepository: CouponRepository,
) {

    @Transactional
    fun insertAndIncrement(event: IssuanceRequested) {
        // 한번더 정합성 검사 하면 좋을것 같음
        if (issuanceRepository.existsByUserIdAndCouponId(event.userId, event.couponId)) return

        issuanceRepository.save(
            Issuance(
                userId = event.userId,
                couponId = event.couponId,
                issuedAt = event.issuedAt,
                expiresAt = event.expiresAt,
            )
        )
        couponRepository.incrementIssueQuantity(event.couponId)
    }

    fun isAlreadyApplied(event: IssuanceRequested): Boolean =
        issuanceRepository.existsByUserIdAndCouponId(event.userId, event.couponId)
}
