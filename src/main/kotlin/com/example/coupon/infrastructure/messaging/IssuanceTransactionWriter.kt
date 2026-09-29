package com.example.coupon.infrastructure.messaging

import com.example.coupon.domain.CouponRepository
import com.example.coupon.domain.Issuance
import com.example.coupon.domain.IssuanceRepository
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional

/**
 * 워커의 실제 @Transactional 경계. INSERT issuance + UPDATE coupon 두 개를 친다.
 *
 * **이 UPDATE 는 한 번 걷어냈다가 되돌아온 것이다. 성능상 알고 쓰는 것이 아니다.**
 *
 * incrementIssueQuantity 는 part-3-3-C(커밋 d6832c5)에서 뺐었다. 그 열은
 * IssuedQuantitySynchronizer 가 1초마다 Redis 재고에서 계산해 **절대값으로 통째로 덮어쓰므로**
 * 워커의 상대적 +1 은 결과에 기여하지 않는데, 선착순이라 모든 발급이 coupon 단일 행을
 * 향하는 탓에 컨슈머들을 그 행 락에 줄 세우기만 했다. 빼자 부하 종료 후 드레인이 통째로
 * 사라졌고, 그것으로 병목이 확정됐다 (docs/load-test-response.md §14.6·§16).
 *
 * 그런데 dlt-replay 작업(커밋 2292479)에서 멱등 검사를 넣으며 **같이 되돌아왔다.**
 * 그 커밋 메시지에 이 줄 얘기는 없다 — 곁다리로 딸려온 것으로 보인다.
 * 지우려던 근거는 지금도 유효하다(동기화기는 여전히 절대값으로 덮어쓴다). 다만
 * 다시 빼면 앱 동작이 바뀌어 새 태그와 재측정이 필요하므로, 지금은 사실만 적어 둔다.
 *
 * 그래서 §16 이후의 응답시간·효율 기록을 읽을 때 주의해야 한다 —
 * 그 절들은 "이 UPDATE 가 없다" 는 전제로 쓰였는데, 2026-08-17 이후 이미지는 있는 상태다.
 */
@Component
class IssuanceTransactionWriter(
    private val issuanceRepository: IssuanceRepository,
    private val couponRepository: CouponRepository,
) {

    @Transactional
    fun insertAndIncrement(event: IssuanceRequested) {
        // 한번더 정합성 검사 하면 좋을것 같음
        if (issuanceRepository.existsByUserIdAndCouponId(event.userId, event.couponId)) return

        issuanceRepository.save(
            Issuance(
                userId = event.userId,
                couponId = event.couponId,
                issuedAt = event.issuedAt,
                expiresAt = event.expiresAt,
            )
        )
        couponRepository.incrementIssueQuantity(event.couponId)
    }

    fun isAlreadyApplied(event: IssuanceRequested): Boolean =
        issuanceRepository.existsByUserIdAndCouponId(event.userId, event.couponId)
}
