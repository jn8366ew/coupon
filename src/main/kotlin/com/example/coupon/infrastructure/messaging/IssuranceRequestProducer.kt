package com.example.coupon.infrastructure.messaging

import org.springframework.kafka.core.KafkaTemplate
import org.springframework.kafka.support.SendResult
import org.springframework.stereotype.Component
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

@Component
class IssuanceRequestProducer(
    private val kafkaTemplate: KafkaTemplate<String, Any>,
) {
    /**
     * 결과 future 를 그대로 돌려준다. 삼키면 send 실패가 아무 데도 드러나지 않아,
     * 사용자는 200 을 받았는데 Redis 재고만 깎인 채 그 한 장이 사라진다.
     *
     * 실패했을 때 무엇을 할지(재고 보상)는 여기서 정하지 않는다. 그것은 발급 정책이고,
     * CouponIssuer 를 아는 application 계층의 몫이다.
     *
     * 파티션 키는 userId — 같은 사용자의 요청이 한 파티션에서 순서대로 처리된다.
     */
    fun publish(event: IssuanceRequested): CompletableFuture<SendResult<String, Any>> =
        kafkaTemplate.send(IssuanceTopics.REQUESTED, event.userId.toString(), event)

    fun publishAndWait(event: IssuanceRequested) {
        kafkaTemplate.send(IssuanceTopics.REQUESTED, event.userId.toString(), event).get(10, TimeUnit.SECONDS)
    }
}
