package com.example.coupon.domain

import jakarta.persistence.LockModeType
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Lock
import org.springframework.data.jpa.repository.Modifying
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param

interface CouponRepository: JpaRepository<Coupon, Long> {
// 비관락인경우
//    @Lock(LockModeType.PESSIMISTIC_WRITE)
//    @Query("Select c from Coupon c where c.id = :id")
//    fun findByIdForUpdate(@Param("id") id: Long): Coupon?

    // 발급 요청마다 이걸 부르면 모든 요청이 coupon 단일 행의 UPDATE 에서 직렬화된다.
    // 핫패스에서는 더 이상 쓰지 않는다. 되돌려 비교할 때를 위해 남겨 둔다.
    @Modifying
    @Query("UPDATE Coupon c SET c.issuedQuantity = c.issuedQuantity + 1 WHERE c.id = :id")
    fun incrementIssueQuantity(@Param("id") id: Long): Int

    // 발급 수를 Redis 에서 계산해 통째로 덮어쓴다 (write-behind).
    // 요청당 한 번이 아니라 주기적으로 한 번이므로 행 경합이 생기지 않는다.
    @Modifying
    @Query("UPDATE Coupon c SET c.issuedQuantity = :issued WHERE c.id = :id")
    fun updateIssuedQuantity(@Param("id") id: Long, @Param("issued") issued: Int): Int
}