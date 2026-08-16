package com.example.coupon.infrastructure.cache

import org.springframework.core.io.ClassPathResource
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.data.redis.core.script.RedisScript

fun listLuaScript(path: String): RedisScript<List<*>> =
    RedisScript.of(ClassPathResource(path), List::class.java)

fun longLuaScript(path: String): RedisScript<Long> =
    RedisScript.of(ClassPathResource(path), Long::class.java)


// 클로드야 이거 보면 쉽게 설명해줄 수 있음? 어린 친구들한테 설명하는것 처럼
@Suppress("UNCHECKED_CAST")
fun StringRedisTemplate.runForStrings(
    script: RedisScript<List<*>>,
    keys: List<String>,
    vararg args: Any,
): List<String> = execute(script, keys, *args.map { it.toString() }. toTypedArray()) as List<String>

// 추후에 사용할 함수
fun StringRedisTemplate.runForLong(
    script: RedisScript<Long>,
    keys: List<String>,
    vararg args: Any,
): Long = execute(script, keys, *args.map { it.toString() }. toTypedArray()) ?: error("Lua 결과 Null")