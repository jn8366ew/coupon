#Requires -Version 5.1
<#
.SYNOPSIS
    쿠폰 한 개를 만들고 그 ID 를 출력한다.

.DESCRIPTION
    강의 원본이 부르는 scripts/load/create_coupon.sh 에 해당한다 (이 저장소에는 없는 경로다).
    재고 5000 은 다른 트랙의 create-coupon.ps1 과 같은 값이다.

    이 트랙에서 재고 크기는 부하 조건이 아니라 "주입한 불일치가 몇 대 몇으로 보이는가" 만
    바꾼다 (기본 주입량 10건 대 재고 5000). 그래도 원본과 맞춰 둔다.

    bash 원본은 jq 로 응답을 파싱하지만 Windows 에는 jq 가 없는 경우가 많아
    PowerShell 이 기본 제공하는 Invoke-RestMethod 로 JSON 을 그대로 객체로 받는다.

.EXAMPLE
    $couponId = .\scripts\consistency\windows\create-coupon.ps1
#>
[CmdletBinding()]
param(
    # localhost 가 아니라 127.0.0.1. Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
    # Docker Desktop 의 ::1 경로가 응답 없이 멈추는 경우가 있다.
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [int]$TotalQuantity = 5000,
    [int]$ValidityDays = 7
)

$ErrorActionPreference = 'Stop'

$body = @{
    name          = 'consistency test'
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

# 파이프라인으로 내보내 호출한 쪽이 변수에 담을 수 있게 한다
$response.id
