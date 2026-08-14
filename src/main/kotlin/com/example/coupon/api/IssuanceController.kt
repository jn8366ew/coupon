package com.example.coupon.api

import com.example.coupon.application.IssuanceService
import com.example.coupon.api.dto.IssuanceResponse
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController


@RestController
@RequestMapping("/api/v1/issuances")
class IssuanceController(
    private val issuanceService: IssuanceService,
) {

    @PostMapping("/{issuanceId}/use")
    fun use(
        @PathVariable("issuanceId") issuanceId: Long,
        @RequestHeader("X-User-Id") userId: Long,
    ): IssuanceResponse {
        val issuance = issuanceService.use(issuanceId, userId)
        return IssuanceResponse.from(issuance)
    }

}