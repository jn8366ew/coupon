#Requires -Version 5.1
<#
.SYNOPSIS
    시나리오 ②(매진 후 새로고침)용 재고 100 장 쿠폰을 만들고 그 ID 를 출력한다.

.DESCRIPTION
    scripts/efficiency/create_small_coupon.sh 의 Windows 판본.

    재고가 작아야 sell-out.ps1 이 100 번 호출로 매진시킬 수 있다.
    100 은 부하 조건의 일부다 — 바꾸면 sell-out.ps1 의 호출 수와
    post_sellout_refresh.js 의 "1~100 을 피한다" 전제가 같이 어긋난다.

    bash 원본은 jq 로 응답을 파싱하지만 Windows 에는 jq 가 없는 경우가 많아
    PowerShell 이 기본 제공하는 Invoke-RestMethod 로 JSON 을 그대로 객체로 받는다.

.EXAMPLE
    $couponId = .\scripts\efficiency\windows\create-small-coupon.ps1
#>
[CmdletBinding()]
param(
    # localhost 가 아니라 127.0.0.1. Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
    # Docker Desktop 의 ::1 경로가 응답 없이 멈추는 경우가 있다.
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [int]$TotalQuantity = 100,
    [int]$ValidityDays = 7
)

$ErrorActionPreference = 'Stop'

$body = @{
    name          = 'sellout test'
    totalQuantity = $TotalQuantity
    validityDays  = $ValidityDays
} | ConvertTo-Json -Compress

try {
    # 컨트롤러 경로는 /api/v1/coupons 다 (CouponController.kt 의 @RequestMapping).
    # mac 원본은 /api/coupons 를 호출한다 — 그대로면 생성 자체가 404 다.
    $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/v1/coupons" `
        -ContentType 'application/json' -Body $body
}
catch {
    Write-Host "!! 쿠폰 생성 실패: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   앱이 $BaseUrl 에서 응답하는지 확인하세요 (docker compose ps)." -ForegroundColor DarkGray
    exit 1
}

if (-not $response.id) {
    Write-Host "!! 응답에 id 가 없습니다: $($response | ConvertTo-Json -Compress)" -ForegroundColor Red
    exit 1
}

$response.id
