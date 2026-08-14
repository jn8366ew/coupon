package com.example.coupon.application

import com.example.coupon.domain.Coupon
import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.domain.IssuanceRepository
import com.example.coupon.support.CouponNotFoundException
import com.example.coupon.support.NotStartedException
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

/**
 * Redis 게이트를 통과한 요청만 여기까지 온다. DB 쓰기만 담당한다.
 *
 * CouponService 안의 private 메서드가 아니라 별도 컴포넌트인 이유:
 * 같은 클래스 안에서 자기 자신을 호출하면 Spring 프록시를 타지 않아 @Transactional 이 걸리지 않는다.
 * 호출부가 트랜잭션 밖에서 실패를 잡아 재고를 되돌려야 하므로 경계가 분명히 나뉘어 있어야 한다.
 */
@Component
class IssuanceWriter(
    private val couponRepository: CouponRepository,
    private val issuanceRepository: IssuanceRepository,
) {
    @Transactional
    fun write(couponId: Long, userId: Long): Issuance {
        val coupon = couponRepository.findById(couponId)
            .orElseThrow { CouponNotFoundException() }

        val now = LocalDateTime.now()

        // 발급 시작 전 판정은 게이트 통과 뒤에 한다. 여기서 예외가 나면 호출부가 재고를 되돌린다.
        if (!coupon.isBookingOpen(now)) {
            throw NotStartedException()
        }

        // coupon.issued_quantity 는 여기서 올리지 않는다.
        //
        // 선착순이라 모든 요청이 coupon 의 같은 행을 건드리는데, InnoDB 는 그 행의 UPDATE 를
        // 직렬화하므로 스레드를 아무리 늘려도 이 한 줄이 처리량 상한이 된다
        // (docs/load-test-k6.md 8.1 절). 재고의 진실은 이제 Redis 가 갖고 있으므로
        // 이 열은 IssuedQuantitySynchronizer 가 주기적으로 맞춰 주는 파생 값이다.
        //
        // 남는 쓰기는 issuance INSERT 뿐이고 이건 행마다 달라 서로 직렬화되지 않는다.
        return issuanceRepository.save(newIssuance(coupon, userId, now))
    }

    private fun newIssuance(coupon: Coupon, userId: Long, now: LocalDateTime) =
        Issuance(
            userId = userId,
            couponId = coupon.id!!,
            issuedAt = now,
            expiresAt = now.plusDays(coupon.validityDays.toLong()),
        )
}
