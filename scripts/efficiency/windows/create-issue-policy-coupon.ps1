#Requires -Version 5.1
<#
.SYNOPSIS
    시나리오 ①(쿠폰 정보 조회 급증)용 쿠폰을 만들고 그 ID 를 출력한다.

.DESCRIPTION
    scripts/efficiency/create_issue_policy_coupon.sh 의 Windows 판본.

    시작 시각(startsAt)을 미래로 박아, issue API 가 쿠폰 정보를 조회한 뒤
    NotStarted 로 끝나게 한다. 재고 차감(Lua)이나 Kafka 발행까지 가지 않으므로
    "쿠폰 정보 조회" 구간만 순수하게 부하를 받는다.

    bash 원본은 jq 로 응답을 파싱하지만 Windows 에는 jq 가 없는 경우가 많아
    PowerShell 이 기본 제공하는 Invoke-RestMethod 로 JSON 을 그대로 객체로 받는다.

    이 스크립트는 호스트에서 돌므로 포트포워딩된 주소를 쓴다.
    (컨테이너 안에서 도는 k6 과 달리 coupon-service 라는 이름은 여기서 해석되지 않는다.)

.EXAMPLE
    $couponId = .\scripts\efficiency\windows\create-issue-policy-coupon.ps1
#>
[CmdletBinding()]
param(
    # localhost 가 아니라 127.0.0.1. Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
    # Docker Desktop 의 ::1 경로가 응답 없이 멈추는 경우가 있다.
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    # 재고는 쓰이지 않는다 (NotStarted 로 끝나므로 차감 자체가 일어나지 않는다).
    [int]$TotalQuantity = 1,
    [int]$ValidityDays = 7,
    # 발급이 절대 열리지 않게 충분히 먼 미래.
    [string]$StartsAt = '2099-01-01T00:00:00'
)

$ErrorActionPreference = 'Stop'

$body = @{
    name          = 'issue policy cache test'
    totalQuantity = $TotalQuantity
    validityDays  = $ValidityDays
    startsAt      = $StartsAt
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

# ID 가 없으면 뒤 단계에서 빈 값으로 엉뚱한 쿠폰을 때리므로 여기서 끊는다
if (-not $response.id) {
    Write-Host "!! 응답에 id 가 없습니다: $($response | ConvertTo-Json -Compress)" -ForegroundColor Red
    exit 1
}

# 파이프라인으로 내보내 호출한 쪽이 변수에 담을 수 있게 한다
$response.id
