package com.example.coupon

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication
import org.springframework.scheduling.annotation.EnableScheduling

// IssuedQuantitySynchronizer 가 coupon.issued_quantity 를 주기적으로 맞춘다.
@EnableScheduling
@SpringBootApplication
class CouponApplication

fun main(args: Array<String>) {
	runApplication<CouponApplication>(*args)
}
