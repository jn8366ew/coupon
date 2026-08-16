package com.example.coupon.infrastructure.cache

import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.stereotype.Repository

@Repository
class IssuanceRedisRepository (
    private val redis: StringRedisTemplate,
    private val soldOutProperties: SoldOutProperties
) {
    private val issueScript = longLuaScript("lua/issue.lua")

    // 반환시 1-성공, 0-매진, -1-중복발급
    fun tryIssue(couponId: Long, userId: Long): Long =
        redis.runForLong(
            issueScript,
            listOf(stockKey(couponId), usersKey(couponId), soldOutKey(couponId)),
            userId, soldOutProperties.ttlSeconds,
        )

    fun initStock(couponId: Long, totalQuantity: Int){
        redis.opsForValue().set(stockKey(couponId), totalQuantity.toString())
    }

    fun remainingStock(couponId: Long): Long? =
        redis.opsForValue().get(stockKey(couponId))?.toLongOrNull()

    private fun stockKey(couponId: Long) = "coupon:$couponId:stock"

    private fun usersKey(couponId: Long) = "coupon:$couponId:users"

    private fun soldOutKey(couponId: Long) = "coupon:$couponId:sold_out"
}