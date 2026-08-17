package com.example.coupon.application

import com.example.coupon.domain.IssuanceDltLog
import com.example.coupon.domain.IssuanceDltLogRepository
import jakarta.transaction.Transactional
import org.apache.kafka.clients.consumer.ConsumerRecord
import org.springframework.kafka.support.KafkaHeaders
import org.springframework.stereotype.Service
import java.nio.charset.StandardCharsets
import java.time.LocalDateTime

@Service
class IssuanceDltService(
    private val issuanceDltLogRepository: IssuanceDltLogRepository,
) {
    @Transactional
    fun record(record: ConsumerRecord<String, ByteArray>) {
        val messageKey = "${record.topic()}: ${record.partition()}:${record.offset()}"
        if (issuanceDltLogRepository.existsByMessageKey(messageKey)) return
        issuanceDltLogRepository.save(
            IssuanceDltLog(
                messageKey = messageKey,
                payload = record.value().toString(StandardCharsets.UTF_8),
                errorMessage = header(record, KafkaHeaders.DLT_EXCEPTION_MESSAGE),
                receivedAt = LocalDateTime.now(),
            ),
        )
    }

    fun findRecent(): List<IssuanceDltLog> = issuanceDltLogRepository.findTop100ByOrderByReceivedAtDesc()

    private fun header(record: ConsumerRecord<*, *>, name: String): String? =
        record.headers().lastHeader(name)?.value()?.toString(StandardCharsets.UTF_8)
}