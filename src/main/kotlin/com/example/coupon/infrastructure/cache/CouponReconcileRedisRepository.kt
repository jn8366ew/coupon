package com.example.coupon.infrastructure.cache

import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.stereotype.Repository
import java.time.Duration

@Repository
class CouponReconcileRedisRepository(
    private val redisTemplate: StringRedisTemplate,
) {
    // 엄... 이게 뭐하는 함수인지 좀 알아야할듯
    // 정확이 이곳에서 뭘 하는지 알아야 할듯.
    fun couponIdsIssuedBetween(fromExclusiveMs: Long, toInclusiveMs: Long): List<Long> {
        if (toInclusiveMs <= fromExclusiveMs) return emptyList()
        val members = redisTemplate.opsForZSet().rangeByScore(
            "coupon:reconcile:recent",
            (fromExclusiveMs + 1).toDouble(),
            toInclusiveMs.toDouble(),
        ) ?: emptySet()
        return members.mapNotNull { it.toLongOrNull() }
    }

    // 주기 대사가 "어디까지 훑었는지" 를 남겨 두는 자리.
    // 앱이 내려가 있었거나 스케줄러가 밀리면 그 사이 발급이 고정 창 밖으로 빠져나가
    // 영영 대사되지 않는데, 이 값이 있으면 다음 회차가 밀린 구간까지 이어서 본다.
    fun watermarkMs(): Long? =
        redisTemplate.opsForValue().get(WATERMARK_KEY)?.toLongOrNull()

    fun updateWatermarkMs(ms: Long) {
        redisTemplate.opsForValue().set(WATERMARK_KEY, ms.toString())
    }

    fun stock(couponId: Long): Long? =
        redisTemplate.opsForValue().get("coupon:$couponId:stock")?.toLongOrNull()

    fun userCount(couponId: Long): Long =
        redisTemplate.opsForValue().size("coupon:$couponId:users") ?: 0L

    fun userIds(couponId: Long): Set<String> =
        redisTemplate.opsForSet().members("coupon:$couponId:users") ?: emptySet()

    fun soldOutExists(couponId: Long): Boolean =
        redisTemplate.hasKey("coupon:$couponId:sold_out")

    fun addUsers(couponId: Long, userIds: Collection<Long>) {
        if (userIds.isEmpty()) return
        redisTemplate.opsForSet().add("coupon:$couponId:users", *userIds.map { it.toString() }.toTypedArray())
    }

    fun deleteSoldOut(couponId: Long) {
        redisTemplate.delete("coupon:$couponId:sold_out")
    }

    fun setSoldOut(couponId: Long, ttlSeconds: Long) {
        redisTemplate.opsForValue().set("coupon:$couponId:sold_out", "1", Duration.ofSeconds(ttlSeconds))
    }

    private companion object {
        const val WATERMARK_KEY = "coupon:reconcile:watermark"
    }
}
