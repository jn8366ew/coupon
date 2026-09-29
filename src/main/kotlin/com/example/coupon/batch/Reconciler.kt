package com.example.coupon.batch

import com.example.coupon.domain.CouponRepository
import com.example.coupon.infrastructure.cache.CouponReconcileRedisRepository
import com.example.coupon.infrastructure.cache.ReconcileProperties
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component


private val log = KotlinLogging.logger {}
@Component
class Reconciler(
    private val couponRepository: CouponRepository,
    private val reconcileRedisRepository: CouponReconcileRedisRepository,
    private val reconcileProperties: ReconcileProperties,
    private val couponReconciler: CouponReconciler
) {
    @Scheduled(fixedRateString = "\${coupon.reconcile.interval-ms}")
    fun scheduledRecent(){
        val cutOffMs = System.currentTimeMillis() - reconcileProperties.gracePeriodMs

        // 기본 창은 지금까지처럼 interval 두 칸이다. 겹치게 잡는 것은 한 회차에서 실패한
        // 쿠폰이 다음 회차에 다시 걸리게 하기 위해서다.
        val slidingFromMs = cutOffMs - reconcileProperties.intervalMs * 2

        // 다만 그 고정 창은 "스케줄러가 제때 돌았다" 를 전제한다. 앱이 내려가 있었거나
        // 실행이 밀리면 그 사이 발급은 창을 지나쳐 버려 영영 대사되지 않는다.
        // 워터마크(지난 회차의 상한)가 더 과거면 그쪽부터 이어서 훑는다 — 창을 넓히기만 하고
        // 좁히지는 않으므로 위의 재시도 성질은 그대로 남는다.
        val fromMs = minOf(slidingFromMs, reconcileRedisRepository.watermarkMs() ?: slidingFromMs)

        if (cutOffMs <= fromMs) return

        if (fromMs < slidingFromMs) {
            log.warn { "대사 공백 감지 — 밀린 구간까지 이어서 훑는다 (from=$fromMs, to=$cutOffMs)" }
        }

        val couponIds = reconcileRedisRepository.couponIdsIssuedBetween(fromMs, cutOffMs)
        reconcileCoupons(couponIds)

        // 훑기가 끝난 뒤에만 전진시킨다. 도중에 터지면 다음 회차가 같은 구간을 다시 본다.
        reconcileRedisRepository.updateWatermarkMs(cutOffMs)
    }

    fun auditAll(): ReconcileReport = reconcileCoupons(couponRepository.findAll().mapNotNull { it.id })

    private fun reconcileCoupons(couponIds: List<Long>): ReconcileReport {
        val outcomes = couponIds.map { couponId ->
            try {
                couponReconciler.reconcile(couponId)
            } catch (e: Exception) {
                log.warn(e) { "reconcile 중 예외 coupon=$couponId, 다음회차에 재시도" }
                CouponReconcileOutcome(driftAlert = true)
            }
        }
        return ReconcileReport(
            autoFixed = outcomes.sumOf { it.autoFixed },
            driftAlerts = outcomes.count { it.driftAlert },
            redisDbDrift = outcomes.sumOf { it.redisDbDrift },
        )
    }
}