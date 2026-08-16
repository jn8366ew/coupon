#Requires -Version 5.1
<#
.SYNOPSIS
    재고 100 장 쿠폰을 100 명에게 발급시켜 매진 상태로 만든다.

.DESCRIPTION
    scripts/efficiency/sell_out.sh 의 Windows 판본. 시나리오 ②의 사전 조건이다.

    발급 컨트롤러는 사용자를 X-User-Id 헤더로 받으므로 1..100 을 순차 호출한다.
    이 100 명은 post_sellout_refresh.js 가 일부러 피하는 구간이다 (거기서는 101 부터 쏜다).

    bash 원본은 끝에 sleep 3 을 두지만, 여기서는 Redis 재고 카운터를 폴링한다.
    기다리는 대상이 시간이 아니라 상태이기 때문이다 — 재고 차감은 Lua 안에서 동기로 끝나므로
    100 번째 호출이 돌아온 시점엔 이미 0 이어야 한다. 아니라면 매진이 안 된 것이고,
    그 상태로 시나리오 ②를 돌리면 fast-path 가 아니라 일반 발급 경로를 재게 된다.

.EXAMPLE
    .\scripts\efficiency\windows\sell-out.ps1 -CouponId 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$CouponId,
    # localhost 가 아니라 127.0.0.1. Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
    # Docker Desktop 의 ::1 경로가 응답 없이 멈추는 경우가 있다.
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    # create-small-coupon.ps1 의 totalQuantity 와 같아야 한다.
    [int]$Users = 100,
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

# docker compose 를 쓰므로 프로젝트 루트에서 돌아야 한다 (scripts/efficiency/windows -> 세 단계 위)
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

Write-Host "$Users 명 순차 발급으로 매진시키는 중..." -ForegroundColor DarkGray

$issued = 0
foreach ($uid in 1..$Users) {
    try {
        Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/v1/coupons/$CouponId/issue" `
            -Headers @{ 'X-User-Id' = "$uid" } | Out-Null
        $issued++
    }
    catch {
        # 원본의 `|| true`. 개별 실패는 넘어가고 최종 판정은 아래 재고 카운터로 한다.
    }
}

Write-Host "발급 요청 수락: $issued / $Users" -ForegroundColor DarkGray

# 재고 카운터(coupon:{id}:stock)가 0 이 될 때까지 기다린다.
$stockKey = "coupon:${CouponId}:stock"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$remaining = $null

while ((Get-Date) -lt $deadline) {
    # redis-cli 출력에 개행/공백이 섞여 오므로 잘라낸다.
    $remaining = (docker compose exec -T redis redis-cli GET $stockKey | Out-String).Trim()
    if ($remaining -eq '0') { break }
    Start-Sleep -Milliseconds 300
}

Write-Host "재고 카운터 = $remaining (0 이어야 매진)"

if ($remaining -ne '0') {
    Write-Host "!! 매진되지 않았습니다." -ForegroundColor Red
    Write-Host "   매진 상태가 아니면 시나리오 ②는 fast-path 가 아니라 일반 발급 경로를 재게 됩니다." -ForegroundColor DarkGray
    Write-Host "   쿠폰 재고(create-small-coupon.ps1 의 TotalQuantity)와 -Users 가 같은지 확인하세요." -ForegroundColor DarkGray
    exit 1
}

# Kafka 워커가 issuance 행을 INSERT 하는 것은 비동기다. 재고 차감(Lua)과 달리 아직 진행 중일 수
# 있는데, 그 쓰기가 k6 구간에 겹치면 측정에 섞인다. 원본의 sleep 3 을 여기에 남겨 둔다.
Start-Sleep -Seconds 3
