package com.example.coupon.application

import org.springframework.core.io.ClassPathResource
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.data.redis.core.script.RedisScript
import org.springframework.stereotype.Component

enum class IssueResult {
    OK,
    SOLD_OUT,
    DUPLICATE,
}

@Component
class CouponIssuer (
    private val redisTemplate: StringRedisTemplate,
) {
    private val script: RedisScript<Long> = RedisScript.of(
        ClassPathResource("lua/issue.lua"),
        Long::class.java,
    )

    /**
     * 발급 자격을 판정하고, 통과하면 그 자리에서 재고를 차감한다.
     * DB 를 전혀 건드리지 않으므로 거절되는 요청은 커넥션조차 잡지 않는다.
     */
    fun tryIssue(couponId: Long, userId: Long): IssueResult {
        val raw = redisTemplate.execute(
            script,
            listOf(stockKey(couponId), issuedKey(couponId)),
            userId.toString(),
        ) ?: error("Lua 스크립트 결과가 Null")

        return when (raw) {
            1L -> IssueResult.OK
            0L -> IssueResult.SOLD_OUT
            -1L -> IssueResult.DUPLICATE
            else -> error("예상치 못한 Lua 결과: $raw")
        }
    }

    /**
     * tryIssue 로 재고를 줄인 뒤 DB 쓰기가 실패했을 때 되돌린다.
     * 되돌리지 않으면 그 한 장은 아무에게도 가지 않은 채 사라지고(과소발급),
     * 사용자는 집합에 남아 다시 시도해도 영영 거절된다.
     */
    fun restore(couponId: Long, userId: Long) {
        redisTemplate.opsForValue().increment(stockKey(couponId))
        redisTemplate.opsForSet().remove(issuedKey(couponId), userId.toString())
    }

    fun initStock(couponId: Long, totalQuantity: Int) {
        redisTemplate.opsForValue().set(stockKey(couponId), totalQuantity.toString())
    }

    fun remainingStock(couponId: Long): Long? =
        redisTemplate.opsForValue().get(stockKey(couponId))?.toLongOrNull()

    private fun stockKey(couponId: Long) = "coupon:$couponId:stock"

    private fun issuedKey(couponId: Long) = "coupon:$couponId:issued"
}
