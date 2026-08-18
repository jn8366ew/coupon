package com.example.coupon.application

interface WaitingRoom {
    fun enter(couponId: Long, userId: Long): Admission
    fun status(couponId: Long, userId: Long): Admission
    fun isAdmitted(couponId: Long, userId: Long): Boolean
}

class Admission(
    val admitted: Boolean,
    val position: Long,
    val estimatedWaitSeconds: Long,
) {
    companion object {
        val ADMITTED: Admission = Admission(true, 0, 0)

        fun waiting(position: Long, admitPerSecond: Int): Admission =
            Admission(false, position, (position + admitPerSecond - 1) / admitPerSecond)
    }
}