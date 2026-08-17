package com.example.coupon.infrastructure.messaging

import com.example.coupon.application.IssuanceDltService
import org.apache.kafka.clients.consumer.ConsumerRecord
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.stereotype.Component

@Component
class IssuanceDltLogConsumer(
    private val issuanceDltService: IssuanceDltService,
) {
    @KafkaListener(
        topics = [IssuanceTopics.REQUESTED_DLT],
        groupId = "issuance-dlt-log",
        containerFactory = "dltKafkaListenerContainerFactory",
    )
    fun consume(record: ConsumerRecord<String, ByteArray>) {
        issuanceDltService.record(record)
    }
}