package com.example.coupon.infrastructure.messaging

import com.example.coupon.application.IssuanceCompensator
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
     * 재시도 1초 x 3회, 그래도 안 되면 <topic>.DLT 로 보내고 **재고를 되돌린다.**
     *
     * DLT 로 보내는 것만으로는 부족하다. 그 시점에 Redis 재고는 이미 깎여 있고 사용자는
     * :users 집합에 남아 있으므로, 되돌리지 않으면 그 한 장은 아무에게도 가지 않은 채 사라지고
     * (과소발급) 그 사용자는 다시 시도해도 영영 거절된다. DB 안에는 모순이 없어 verify 는
     * 전부 OK 로 통과한다 — 발행 실패 쪽에서 막았던 것과 같은 실패 모드다
     * (docs/load-test-k6.md 14.7 / 17).
     */
    @Bean
    fun errorHandler(
        template: KafkaTemplate<String, Any>,
        compensator: IssuanceCompensator,
    ): DefaultErrorHandler {
        val deadLetterPublisher = DeadLetterPublishingRecoverer(template) { record, _ ->
            TopicPartition("${record.topic()}.DLT", record.partition())
        }

        val recoverer = ConsumerRecordRecoverer { record, exception ->
            // 순서가 중요하다. 먼저 DLT 에 보존하고 그 다음에 되돌린다.
            // DLT 발행이 실패하면 여기서 예외가 나가 오프셋이 안 올라가고 재처리된다 — 유실보다 낫다.
            // 반대 순서였다면 재고만 돌아오고 메시지는 사라지는 창이 생긴다.
            deadLetterPublisher.accept(record, exception)

            when (val event = record.value()) {
                is IssuanceRequested ->
                    compensator.compensate(event.couponId, event.userId, exception, PHASE)

                // 역직렬화 실패라 값이 없다. 키(userId)는 있지만 couponId 를 알 수 없어 되돌릴 수 없다.
                // 조용히 넘어가면 재고가 샌 채로 남으므로 크게 남긴다.
                else -> log.error(exception) {
                    "$PHASE 실패 — DLT 로 보냈으나 재고를 되돌리지 못했다(이벤트를 읽을 수 없음): " +
                        "topic=${record.topic()}, partition=${record.partition()}, " +
                        "offset=${record.offset()}, key=${record.key()}"
                }
            }
        }

        return DefaultErrorHandler(recoverer, FixedBackOff(1_000L, 3L))
    }

    companion object {
        private const val PHASE = "발급 기록(DLT 이관)"
    }
}
