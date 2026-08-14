package com.example.coupon.infrastructure.messaging

import org.apache.kafka.common.TopicPartition
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer
import org.springframework.kafka.listener.DefaultErrorHandler
import org.springframework.util.backoff.FixedBackOff

@Configuration
class KafkaErrorHandlerConfig {

    @Bean
    fun errorHandler(template: KafkaTemplate<String, Any>): DefaultErrorHandler {
        var recoverer = DeadLetterPublishingRecoverer(template) { record, _ ->
            TopicPartition("${record.topic()}.DLT", record.partition())
        }
        return DefaultErrorHandler(recoverer, FixedBackOff(1_000L, 3L))
    }
}