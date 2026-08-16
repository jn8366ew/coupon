package com.example.coupon.infrastructure.messaging

import io.github.oshai.kotlinlogging.KotlinLogging
import org.apache.kafka.common.TopicPartition
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.kafka.listener.ConsumerRecordRecoverer
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer
import org.springframework.kafka.listener.DefaultErrorHandler
import org.springframework.util.backoff.FixedBackOff

private val log = KotlinLogging.logger {}

@Configuration
class KafkaErrorHandlerConfig {

    /**
     * 재시도 1초 x 3회, 그래도 안 되면 <topic>.DLT 로 보낸다.
     *
     * **재고는 되돌리지 않는다.** 4-4 에서 보상(restore)을 걷어냈기 때문이다
     * (docs/architecture.md 4). 그 시점에 Redis 재고는 이미 깎여 있고 사용자는 :users 에
     * 남아 있으므로, 그 한 장은 아무에게도 가지 않은 채 사라지고(과소발급) 그 사용자는
     * 다시 시도해도 거절된다. DB 안에는 모순이 없어 verify 는 전부 OK 로 통과한다 —
     * 그래서 이 로그가 유일한 흔적이다.
     */
    @Bean
    fun errorHandler(template: KafkaTemplate<String, Any>): DefaultErrorHandler {
        val deadLetterPublisher = DeadLetterPublishingRecoverer(template) { record, _ ->
            TopicPartition("${record.topic()}.DLT", record.partition())
        }

        val recoverer = ConsumerRecordRecoverer { record, exception ->
            // DLT 발행이 실패하면 여기서 예외가 나가 오프셋이 안 올라가고 재처리된다 — 유실보다 낫다.
            deadLetterPublisher.accept(record, exception)

            log.error(exception) {
                "$PHASE 실패 — DLT 로 보냈다. 재고는 깎인 채로 남는다: " +
                    "topic=${record.topic()}, partition=${record.partition()}, " +
                    "offset=${record.offset()}, key=${record.key()}"
            }
        }

        return DefaultErrorHandler(recoverer, FixedBackOff(1_000L, 3L))
    }

    companion object {
        private const val PHASE = "발급 기록(DLT 이관)"
    }
}
