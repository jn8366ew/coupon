package com.example.coupon.api

import com.example.coupon.api.dto.ReconcileRunResponse
import com.example.coupon.batch.Reconciler
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/admin/reconcile")
class AdminReconcileController(
    private val reconciler: Reconciler,
){
    @PostMapping("/run")
    fun run(): ReconcileRunResponse =
        ReconcileRunResponse.from(reconciler.auditAll())
}