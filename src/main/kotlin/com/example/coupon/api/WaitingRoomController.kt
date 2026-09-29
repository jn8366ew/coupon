package com.example.coupon.api

import com.example.coupon.api.dto.WaitingRoomResponse
import com.example.coupon.application.WaitingRoom
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/waiting-room")
class WaitingRoomController(
    private val waitingRoom: WaitingRoom,
) {

    @PostMapping("/{couponId}")
    fun enter(
        @PathVariable couponId: Long,
        @RequestHeader("X-User-Id") UserId: Long,
    ): WaitingRoomResponse = WaitingRoomResponse.from(waitingRoom.enter(couponId, UserId))

    @GetMapping("{couponId}")
    fun status(
        @PathVariable couponId: Long,
        @RequestHeader("X-User-Id") UserId: Long,
    ): WaitingRoomResponse = WaitingRoomResponse.from(waitingRoom.status(couponId, UserId))

}