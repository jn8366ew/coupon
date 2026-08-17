package com.example.coupon.domain

import jakarta.persistence.Column
import jakarta.persistence.Entity
import jakarta.persistence.EnumType
import jakarta.persistence.Enumerated
import jakarta.persistence.GeneratedValue
import jakarta.persistence.GenerationType
import jakarta.persistence.Id
import jakarta.persistence.Index
import jakarta.persistence.Table
import java.time.LocalDateTime

@Entity
@Table(name = "issuance_dlt_log",
    indexes = [
        Index(name = "idx_issuance_dlt_message_key", columnList = "message_key")
    ]
)
class IssuanceDltLog(
    @Column(nullable = false, length = 300)
    var messageKey: String,

    @Column(nullable = false, columnDefinition = "TEXT")
    var payload: String,

    @Column(columnDefinition = "TEXT")
    var errorMessage: String? = null,

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 16)
    var status: IssuanceDltStatus = IssuanceDltStatus.PENDING,

    @Column(nullable = false)
    var receivedAt: LocalDateTime,

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null,
)
