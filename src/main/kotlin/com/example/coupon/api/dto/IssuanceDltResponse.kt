package com.example.coupon.api.dto

import com.example.coupon.domain.IssuanceDltLog
import java.time.LocalDateTime

class IssuanceDltResponse(
    val id: Long,
    val messageKey: String,
    val payload: String,
    val errorMessage: String?,
    val status: String,
    val receivedAt: LocalDateTime,
) {
    companion object {
        fun from(log: IssuanceDltLog) = IssuanceDltResponse(
            id = log.id!!,
            messageKey = log.messageKey,
            payload = log.payload,
            errorMessage = log.errorMessage,
            status = log.status.name,
            receivedAt = log.receivedAt,
        )
    }
}