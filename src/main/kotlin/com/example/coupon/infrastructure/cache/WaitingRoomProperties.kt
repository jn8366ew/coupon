package com.example.coupon.infrastructure.cache

import org.springframework.boot.context.properties.ConfigurationProperties



@ConfigurationProperties(prefix = "coupon.waiting-room")
class WaitingRoomProperties(
    val admitPerSecond: Int,
    val passTtlMs: Long,
) {
    init {
        require(admitPerSecond > 0) { "admitPerSecond must be positive" }
        require(passTtlMs > 0) { "passTtlMs must be positive" }
    }
}