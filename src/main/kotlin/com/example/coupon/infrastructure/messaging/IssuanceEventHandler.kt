package com.example.coupon.infrastructure.messaging

import org.springframework.context.event.EventListener
import org.springframework.scheduling.annotation.Async
import org.springframework.stereotype.Component

@Component
class IssuanceEventHandler(
    private val writer: IssuanceWriter,
) {
    @Async(ISSUANCE_TASK_EXECUTOR)
    @EventListener
    fun handle(event: IssuanceRequested) {
        writer.write(event)
    }
}