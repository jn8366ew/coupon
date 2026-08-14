package com.example.coupon.application

import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.stereotype.Component

private val log = KotlinLogging.logger {}

/**
 * tryIssue 로 얻은 발급 자격을 되돌린다.
 *
 * 되돌리지 않으면 그 한 장은 아무에게도 가지 않은 채 사라지고(과소발급),
 * 사용자는 :users 집합에 남아 다시 시도해도 영영 거절된다.
 * DB 안에는 아무 모순이 없어 verify 의 세 판정은 전부 OK 로 통과한다.
 *
 * 부르는 곳이 둘이라 여기 모아 뒀다. 둘 다 "Redis 는 깎였는데 그 발급이 성사되지 못했다" 는
 * 같은 상황이고, 정책이 갈라지면 한쪽만 고치는 실수가 난다.
 *
 *   - 발행 실패: CouponService.issue — Kafka 에 넣지 못했다
 *   - 소비 실패: KafkaErrorHandlerConfig — 워커가 3회 재시도 끝에 DLT 로 보냈다
 */
@Component
class IssuanceCompensator(
    private val couponIssuer: CouponIssuer,
) {
    /**
     * 보상 자체가 실패하는 경우까지는 막지 못한다 (Redis 가 죽어 있으면 되돌릴 수단이 없다).
     * 그때는 로그가 유일한 흔적이므로 ERROR 로 남긴다.
     *
     * @param phase 어느 경로에서 실패했는지. 로그에 그대로 실린다
     */
    fun compensate(couponId: Long, userId: Long, cause: Throwable, phase: String) {
        try {
            val restored = couponIssuer.restore(couponId, userId)
            log.error(cause) {
                "$phase 실패 — 재고 보상 ${if (restored) "완료" else "불필요(이미 되돌아감)"}: " +
                    "couponId=$couponId, userId=$userId"
            }
        }
        catch (e: Exception) {
            log.error(e) { "$phase 실패 후 재고 보상마저 실패: couponId=$couponId, userId=$userId" }
        }
    }
}
