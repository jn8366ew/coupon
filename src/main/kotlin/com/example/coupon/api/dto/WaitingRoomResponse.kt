package com.example.coupon.api.dto

import com.example.coupon.application.Admission

class WaitingRoomResponse(
    val admitted: Boolean,
    val position: Long,
    val estimateWaitSeconds: Long
) {
    companion object {
        fun from(admission: Admission): WaitingRoomResponse = WaitingRoomResponse(
            admitted = admission.admitted,
            position = admission.position,
            estimateWaitSeconds = admission.estimatedWaitSeconds,
        )
    }
}