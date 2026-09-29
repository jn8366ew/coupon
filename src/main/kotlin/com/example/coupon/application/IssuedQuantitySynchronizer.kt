package com.example.coupon.application

import com.example.coupon.domain.CouponRepository
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional

/**
 * coupon.issued_quantity 를 Redis 재고에서 파생시켜 주기적으로 반영한다 (write-behind).
 *
 * 발급 요청마다 카운터를 올리면 모든 요청이 같은 행의 UPDATE 에서 줄을 서게 되므로,
 * 실시간 판정은 Redis 에 맡기고 DB 열은 뒤따라오게 둔다.
 *
 * 그래서 이 열은 이제 "Redis 가 센 발급 수" 다. 검증 SQL 의 count_match 는
 * 그 값과 "DB 에 실제로 들어간 issuance 행 수" 를 비교하게 되어,
 * 두 저장소가 어긋나면 잡아내는 교차 검증이 된다.
 * (COUNT(*) 로 채우면 언제나 일치해 검증이 아무것도 못 잡는다.)
 *
 * 주기를 property 로 뺀 이유 — part-5 정합성 검증(대사)은 이 열을 반대 뜻으로 읽는다.
 * 거기서는 "DB 가 아는 발급 수" 여야 하는데, 이 동기화기가 켜져 있으면
 * issued_quantity = totalQuantity - stock 이 되어 대사의
 *     dbDrift = totalQuantity - (issuedQuantity + stock)
 * 가 항상 정확히 0 이 된다 — DB 측 불일치를 원리적으로 못 잡는다.
 * 그래서 그 검증 동안만 주기를 크게 줘서 사실상 꺼 둔다
 * (scripts/consistency/windows/run-v2.ps1 이 COUPON_SYNC_INTERVAL_MS 로 넘긴다).
 */
@Component
class IssuedQuantitySynchronizer(
    private val couponRepository: CouponRepository,
    private val couponIssuer: CouponIssuer,
) {
    @Scheduled(fixedDelayString = "\${coupon.sync.interval-ms}")
    @Transactional
    fun sync() {
        couponRepository.findAll().forEach { coupon ->
            val couponId = coupon.id ?: return@forEach
            val remaining = couponIssuer.remainingStock(couponId) ?: return@forEach

            val issued = (coupon.totalQuantity - remaining).coerceIn(0, coupon.totalQuantity.toLong()).toInt()
            if (issued != coupon.issuedQuantity) {
                couponRepository.updateIssuedQuantity(couponId, issued)
            }
        }
    }
}
