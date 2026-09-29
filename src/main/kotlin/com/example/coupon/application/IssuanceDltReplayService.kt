package com.example.coupon.application

import com.example.coupon.domain.IssuanceDltLog
import com.example.coupon.domain.IssuanceDltLogRepository
import com.example.coupon.domain.IssuanceDltStatus
import com.example.coupon.infrastructure.messaging.IssuanceRequestProducer
import com.example.coupon.infrastructure.messaging.IssuanceRequested
import jakarta.transaction.Transactional
import org.springframework.stereotype.Service
import tools.jackson.databind.json.JsonMapper

@Service
class IssuanceDltReplayService(
    private val issuanceDltLogRepository: IssuanceDltLogRepository,
    private val issuanceRequestProducer: IssuanceRequestProducer
) {
    // 사실 학습을 위한 용도가 아니면 이렇게 코드를 만들 이유는 없음
    private val jsonMapper = JsonMapper.builder().findAndAddModules().build()
    @Transactional
    fun replay(ids: List<Long>): Int {
        val selectedIds = ids.distinct()
        // 검증
        require(selectedIds.isNotEmpty()) { "At least one DLT log id is required" }
        require(selectedIds.size <= MAX_REPLAY_COUNT) { "At most $MAX_REPLAY_COUNT DLT logs can be replayed" }

        val logs = issuanceDltLogRepository.findAllByIdForUpdate(selectedIds).sortedBy { it.receivedAt }
        check(logs.size == selectedIds.size) {"Some DLT logs were not found"}

        val events = logs.map { log ->
            check(log.status == IssuanceDltStatus.PENDING){
                "Only pending DLT logs can be replayed: ${log.id}"
            }
            log.toEvent()
        }
        logs.zip(events).forEach { (log, event) ->
            // 여기는 비동기까지 않지 않고 wait 까지. 받아야 로그 사이즈를 리턴
            issuanceRequestProducer.publishAndWait(event)
            log.status = IssuanceDltStatus.REPLAYED
        }
        return logs.size
    }

    private fun IssuanceDltLog.toEvent(): IssuanceRequested =
        jsonMapper.readValue(payload, IssuanceRequested::class.java)

    private companion object {
        const val MAX_REPLAY_COUNT = 100
    }
}
