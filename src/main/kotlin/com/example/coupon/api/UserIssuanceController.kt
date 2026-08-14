package com.example.coupon.api

import com.example.coupon.application.IssuanceService
import com.example.coupon.api.dto.IssuanceResponse
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController


@RestController
@RequestMapping("/api/v1/users/me/issuances")
class UserIssuanceController(
    private val issuanceService: IssuanceService,
) {
    @GetMapping
    fun listMine(@RequestHeader("X-User-Id") userId: Long): List<IssuanceResponse> =
        issuanceService.findByUser(userId).map(IssuanceResponse::from)
}