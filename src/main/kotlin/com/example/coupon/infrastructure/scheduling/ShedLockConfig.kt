package com.example.coupon.infrastructure.scheduling

import net.javacrumbs.shedlock.core.LockProvider
import net.javacrumbs.shedlock.provider.redis.spring.RedisLockProvider
import net.javacrumbs.shedlock.spring.annotation.EnableSchedulerLock
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.data.redis.connection.RedisConnectionFactory

@Configuration
@EnableSchedulerLock(defaultLockAtMostFor = "PT10S")

class ShedLockConfig {
    @Bean
    fun lockProvider(connectionFactory: RedisConnectionFactory): LockProvider =
        RedisLockProvider(connectionFactory, "coupon")
}