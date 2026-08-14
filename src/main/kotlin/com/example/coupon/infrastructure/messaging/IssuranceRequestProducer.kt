package com.example.coupon.infrastructure.messaging

import org.springframework.kafka.core.KafkaTemplate
import org.springframework.stereotype.Component

@Component
class IssuanceRequestProducer(
    private val kafkaTemplate: KafkaTemplate<String, Any>,
) {
    fun publish(event: IssuanceRequested) {
        kafkaTemplate.send(IssuanceTopics.REQUESTED, event.userId.toString(), event)
    }
}