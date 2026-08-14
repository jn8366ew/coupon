package com.example.coupon.infrastructure.messaging

import com.example.coupon.infrastructure.messaging.IssuanceWriter
import io.github.oshai.kotlinlogging.KotlinLogging
import jakarta.annotation.PostConstruct
import jakarta.annotation.PreDestroy
import org.springframework.stereotype.Component
import kotlin.concurrent.thread

private val log = KotlinLogging.logger {}

@Component
class InMemoryIssuanceWorker(
    private val queue: InMemoryIssuanceQueue,
    private val writer: IssuanceWriter,
) {
    private lateinit var workerThread: Thread

    @PostConstruct
    fun start() {
        workerThread = thread(name= "issuance-worker", isDaemon = true) {
            while (!Thread.currentThread().isInterrupted) {
                val event = try {
                    queue.poll() ?: continue
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
                try {
                    writer.write(event)
                } catch (e: Exception) {
                    log.error {"Worker write 실패: couponId=${event.couponId}, userId=${event.userId}"}
                }
            }
        }
    }

    @PreDestroy
    fun stop() {
        if (::workerThread.isInitialized) {
            workerThread.interrupt()
        }
    }
}