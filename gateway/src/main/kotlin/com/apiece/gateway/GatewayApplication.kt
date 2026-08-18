package com.apiece.gateway

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication
import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver
import org.springframework.context.annotation.Bean
import reactor.core.publisher.Mono

@SpringBootApplication
class GatewayApplication {
    @Bean
    fun userIdKeyResolver(): KeyResolver = KeyResolver { exchange ->
        var userId = exchange.request.headers[USER_ID_HEADER]
            ?.singleOrNull()
            ?.toLongOrNull()
            ?.takeIf{ it > 0 }
        if (userId == null) Mono.empty() else Mono.just("user:$userId")
    }

    private companion object {
        const val USER_ID_HEADER = "X-User-Id"
    }
}

fun main(args: Array<String>) {
    runApplication<GatewayApplication>(*args)
}