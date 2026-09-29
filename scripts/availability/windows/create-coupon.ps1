#Requires -Version 5.1
<#
.SYNOPSIS
    쿠폰 한 개를 만들고 그 ID 를 출력한다.

.DESCRIPTION
    scripts/availability/run.sh 가 부르는 create_coupon.sh 의 Windows 판본.
    bash 판은 jq 로 응답을 파싱하지만 Windows 에는 jq 가 없는 경우가 많아
    PowerShell 이 기본 제공하는 Invoke-RestMethod 로 JSON 을 그대로 객체로 받는다.

    재고가 100만인 것이 이 트랙의 핵심이다. 가용성 트랙이 재는 것은 "매진" 이 아니라
    "대기실이 얼마나 통과시키는가" 이므로, 측정 중에 매진이 나면 재는 대상이 바뀐다
    (다른 트랙의 create-coupon.ps1 은 5,000 이 기본이다 — 그대로 쓰면 안 된다).

    이 스크립트는 호스트에서 돌므로 포트포워딩된 127.0.0.1 을 쓴다.
    (컨테이너 안에서 도는 k6 과 달리 coupon-service 라는 이름은 여기서 해석되지 않는다.)

.EXAMPLE
    $couponId = .\scripts\availability\windows\create-coupon.ps1
    쿠폰을 만들고 ID 를 변수에 담는다.
#>
[CmdletBinding()]
param(
    # localhost 가 아니라 127.0.0.1. Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
    # Docker Desktop 의 ::1 경로가 응답 없이 멈추는 경우가 있다.
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [long]$TotalQuantity = 1000000,
    [int]$ValidityDays = 7
)

$ErrorActionPreference = 'Stop'

$body = @{
    name          = 'availability test'
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

# ID 가 없으면 뒤 단계에서 빈 값으로 이상한 SQL 이 만들어지므로 여기서 끊는다
if (-not $response.id) {
    Write-Host "!! 응답에 id 가 없습니다: $($response | ConvertTo-Json -Compress)" -ForegroundColor Red
    exit 1
}

# 파이프라인으로 내보내 호출한 쪽이 변수에 담을 수 있게 한다
$response.id
