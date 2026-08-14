package com.example.coupon.application

import com.example.coupon.support.AlreadyIssuedException
import com.example.coupon.support.SoldOutException
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

    private val restoreScript: RedisScript<Long> = RedisScript.of(
        ClassPathResource("lua/restore.lua"),
        Long::class.java,
    )

    /**
     * 발급 자격을 판정하고, 통과하면 그 자리에서 재고를 차감한다.
     * DB 를 전혀 건드리지 않으므로 거절되는 요청은 커넥션조차 잡지 않는다.
     */
    fun tryIssue(couponId: Long, userId: Long) {
        val raw = redisTemplate.execute(
            script,
            listOf(stockKey(couponId), usersKey(couponId)),
            userId.toString(),
        ) ?: error("Lua 스크립트 결과가 Null")

        return when (raw) {
            1L -> Unit
            0L -> throw SoldOutException()
            -1L -> throw AlreadyIssuedException()
            else -> error("예상치 못한 Lua 결과: $raw")
        }
    }

    /**
     * tryIssue 로 얻은 발급 자격을 되돌린다 (큐에 넣지 못했을 때).
     * 되돌리지 않으면 그 한 장은 아무에게도 가지 않은 채 사라지고(과소발급),
     * 사용자는 집합에 남아 다시 시도해도 영영 거절된다.
     *
     * @return true 면 되돌렸다. false 면 되돌릴 것이 없었다(이미 되돌렸거나 발급된 적 없다).
     */
    fun restore(couponId: Long, userId: Long): Boolean {
        val raw = redisTemplate.execute(
            restoreScript,
            listOf(stockKey(couponId), usersKey(couponId)),
            userId.toString(),
        )
        return raw == 1L
    }

    fun initStock(couponId: Long, totalQuantity: Int) {
        redisTemplate.opsForValue().set(stockKey(couponId), totalQuantity.toString())
    }

    fun remainingStock(couponId: Long): Long? =
        redisTemplate.opsForValue().get(stockKey(couponId))?.toLongOrNull()

    private fun stockKey(couponId: Long) = "coupon:$couponId:stock"

    private fun usersKey(couponId: Long) = "coupon:$couponId:users"
}
