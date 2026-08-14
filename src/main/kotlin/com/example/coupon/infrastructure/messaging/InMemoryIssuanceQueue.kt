package com.example.coupon.infrastructure.messaging

import com.example.coupon.support.QueueFullException
import org.springframework.stereotype.Component
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

@Component
class InMemoryIssuanceQueue {
    private val queue = LinkedBlockingQueue<IssuanceRequested>(CAPACITY)

    fun enqueue(event: IssuanceRequested) {
        if (!queue.offer(event))
            throw QueueFullException()
    }

    fun poll(): IssuanceRequested? = queue.poll(POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS)

    fun size(): Int = queue.size

    companion object {
        private const val CAPACITY = 10000
        private const val POLL_TIMEOUT_MS = 100L
    }
}