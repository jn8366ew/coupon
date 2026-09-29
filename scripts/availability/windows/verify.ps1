#Requires -Version 5.1
<#
.SYNOPSIS
    Redis 대기실의 기능 정오를 PASS/FAIL 로 확인한다 (숫자를 재지 않는다).

.DESCRIPTION
    scripts/availability/verify.sh 의 Windows 판본. 검증 항목과 기대값은 원본과 같다.

    원본과 다른 점:
      - 게이트 경로가 com/apiece/... 가 아니라 com/example/... 다 (이 저장소의 패키지).
      - 발급 경로가 /api/coupons 가 아니라 /api/v1/coupons 다. 대기실만 /api/waiting-room (v1 없음).
      - 원본의 색 있는 체크표시 대신 PASS / FAIL 표기를 쓴다 (CP949 콘솔에서 깨진다).
      - 순번 검증 블록에 경합 감지 + 재시도가 붙어 있다 (아래).

    왜 재시도가 필요한가
      드레인이 매초 admitPerSecond 명을 통과시킨다. 3명이 진입하고 재진입을 확인하는 사이에
      드레인 틱이 끼면 user 1 이 이미 입장권을 갖고 position 0 을 돌려준다
      (waiting-room-enter.lua 는 입장권이 있으면 통과로 답한다). 결함이 아니라 경합이므로
      그 상황을 감지해 새 쿠폰으로 블록을 다시 돌린다. 계속 걸리면 조용히 통과시키지 않고
      그 사실을 적어 FAIL 로 낸다.

.EXAMPLE
    .\scripts\availability\windows\verify.ps1
#>
[CmdletBinding()]
param(
    # localhost 가 아니라 127.0.0.1 (Windows 에서 ::1 로 먼저 해석돼 멈추는 경우가 있다).
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [long]$TotalQuantity = 1000000,
    # 순번 블록이 드레인과 경합했을 때 새 쿠폰으로 다시 시도할 횟수
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'

# scripts/availability/windows -> 저장소 루트
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# ---------------------------------------------------------------------------
# 출력 헬퍼 — 트랙마다 일부러 복제한다 (_common.ps1 선례가 이 저장소에 없다).
# 원본은 색 있는 체크표시를 쓰지만 CP949 콘솔에서 물음표로 깨지므로 PASS / FAIL 로 쓴다.
# ---------------------------------------------------------------------------
$script:Fail = 0

function Write-Pass {
    param([string]$Message)
    Write-Host "  PASS " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Ng {
    param([string]$Message)
    Write-Host "  FAIL " -ForegroundColor Red -NoNewline
    Write-Host $Message
    $script:Fail = 1
}

function Test-Expected {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Actual,
        [AllowEmptyString()][string]$Expected
    )

    if ($Actual -eq $Expected) { Write-Pass "$Label ($Actual)" }
    else { Write-Ng "$Label (실제 $Actual, 기대 $Expected)" }
}

# 상태 코드만 필요할 때. 원본은 curl -w 로 끝나지만 PowerShell 은 4xx/5xx 에서 예외를 던지고,
# 코드를 꺼내는 방법이 5.1 과 7 에서 다르다.
# [int] 캐스팅은 양쪽(5.1 의 HttpStatusCode 열거형 / 7 의 값) 다 통한다.
function Get-HttpStatus {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        [hashtable]$Headers = @{}
    )

    try {
        return [int](Invoke-WebRequest -Method $Method -Uri $Uri -Headers $Headers `
                -TimeoutSec 10 -UseBasicParsing).StatusCode
    }
    catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
        return 0   # 연결 자체가 안 됐다 (앱이 안 떠 있음)
    }
}

# 대기실 응답 { admitted, position, estimateWaitSeconds } 을 객체로 받는다.
function Enter-WaitingRoom {
    param([Parameter(Mandatory)][string]$CouponId, [Parameter(Mandatory)][string]$UserId)
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/waiting-room/$CouponId" `
        -Headers @{ 'X-User-Id' = $UserId } -TimeoutSec 10
}

function Get-WaitingRoomStatus {
    param([Parameter(Mandatory)][string]$CouponId, [Parameter(Mandatory)][string]$UserId)
    Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/waiting-room/$CouponId" `
        -Headers @{ 'X-User-Id' = $UserId } -TimeoutSec 10
}

# 0.25초 간격으로 20회 — 드레인 주기(1초)의 다섯 배까지 기다린다.
function Wait-Admitted {
    param([Parameter(Mandatory)][string]$CouponId, [Parameter(Mandatory)][string]$UserId)

    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-WaitingRoomStatus -CouponId $CouponId -UserId $UserId).admitted) { return 'true' }
        Start-Sleep -Milliseconds 250
    }
    return 'false'
}

# ---------------------------------------------------------------------------
# 사전 조건 — 소스에 구현이 있는지 (원본의 require_source)
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath 'src/main/kotlin/com/example/coupon/application/RedisWaitingRoom.kt')) {
    Write-Host "!! verify 는 part-6-1-waiting-room 이후에 실행할 수 있습니다." -ForegroundColor Red
    Write-Host "   src/main/kotlin/com/example/coupon/application/RedisWaitingRoom.kt 가 없습니다." -ForegroundColor DarkGray
    exit 1
}

Write-Host ""
Write-Host "===== part-6-1 Redis 대기실 검증 =====" -ForegroundColor Cyan

# 소스에 있다고 떠 있는 이미지에도 있는 것은 아니다. 리셋보다 먼저 확인한다 —
# 안 그러면 데이터를 다 날린 뒤 첫 진입 요청에서 404 로 죽는다 (CLAUDE.md).
# 없는 쿠폰 번호로 찔러본다. 진입은 Redis 만 건드리므로 200 이 정상이고,
# 이때 생기는 waiting:{999999}:queue 는 바로 다음 리셋의 FLUSHALL 이 지운다.
$probeOk = $false
try {
    $probe = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/waiting-room/999999" `
        -Headers @{ 'X-User-Id' = '1' } -TimeoutSec 5
    $probeOk = ($null -ne $probe.PSObject.Properties['admitted'])
}
catch { }

if (-not $probeOk) {
    Write-Host "!! 떠 있는 앱에 대기실 엔드포인트가 없습니다 ($BaseUrl/api/waiting-room)." -ForegroundColor Red
    Write-Host "   소스에는 있지만 그 코드가 든 이미지가 떠 있지 않다는 뜻입니다." -ForegroundColor DarkGray

    # "빌드하세요" 만 말하면 방금 빌드한 사람에게는 무한 루프로 보인다.
    # 실제로 무엇이 떠 있는지, .env 가 고른 태그와 같은지까지 보여준다 —
    # 빌드가 필요한 상황과 태그가 안 먹은 상황은 대응이 다르다.
    $runningImage = $null
    $containerId = (docker compose ps -q coupon-service | Select-Object -First 1)
    if ($containerId) {
        $runningImage = docker inspect --format '{{.Config.Image}}' $containerId
        Write-Host "   실제로 떠 있는 이미지: $runningImage" -ForegroundColor DarkGray
    }
    else {
        Write-Host "   coupon-service 컨테이너가 떠 있지 않습니다." -ForegroundColor DarkGray
    }

    $envTag = $null
    if (Test-Path -LiteralPath '.env') {
        $envTagLine = @(Get-Content -LiteralPath '.env') |
            Where-Object { $_ -like 'COUPON_IMAGE_TAG=*' } | Select-Object -First 1
        if ($envTagLine) { $envTag = ($envTagLine -split '=', 2)[1] }
    }
    if ($envTag) {
        Write-Host "   .env 가 고른 태그: $envTag" -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($envTag -and $runningImage -and $runningImage -ne "coupon-service:$envTag") {
        # 빌드는 됐는데 compose 가 그 태그를 안 읽고 있는 경우.
        Write-Host "   태그를 골랐는데 다른 이미지가 떠 있습니다 — docker-compose.yml 의" -ForegroundColor Yellow
        Write-Host "   coupon-service.image 가 태그를 읽는지 확인하세요:" -ForegroundColor DarkGray
        Write-Host "       image: coupon-service:`${COUPON_IMAGE_TAG:-latest}" -ForegroundColor Yellow
        Write-Host "   고친 뒤 (이미지는 이미 있으므로 다시 빌드하지 않습니다):" -ForegroundColor DarkGray
        Write-Host "       .\build-and-run.ps1 -Tag $envTag -NoBuild" -ForegroundColor Yellow
    }
    else {
        Write-Host "   대기실이 든 새 태그로 빌드해서 띄우세요:" -ForegroundColor DarkGray
        Write-Host "       .\build-and-run.ps1 -Tag waiting-room" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "   (예전 태그로 되돌아갈 때는 -NoBuild 를 반드시 붙입니다 — CLAUDE.md)" -ForegroundColor DarkGray
    exit 1
}

& "$PSScriptRoot\reset.ps1" | Out-Null

# ---------------------------------------------------------------------------
# [순서 보장] + [진입 멱등성] + [상태 조회] — 드레인과 경합하면 새 쿠폰으로 다시
# ---------------------------------------------------------------------------
$ordering = $null

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $couponId = & "$PSScriptRoot\create-coupon.ps1" -BaseUrl $BaseUrl -TotalQuantity $TotalQuantity
    if (-not $couponId) {
        Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red
        exit 1
    }
    Write-Host "쿠폰 $couponId 생성" -ForegroundColor DarkGray

    $e1 = Enter-WaitingRoom -CouponId $couponId -UserId '1'
    $e2 = Enter-WaitingRoom -CouponId $couponId -UserId '2'
    $e3 = Enter-WaitingRoom -CouponId $couponId -UserId '3'
    $reenter1 = Enter-WaitingRoom -CouponId $couponId -UserId '1'
    $status2 = Get-WaitingRoomStatus -CouponId $couponId -UserId '2'

    # 이 블록이 도는 동안 드레인이 통과시켰다면 순번이 아니라 입장권을 본 것이다.
    $raced = $e1.admitted -or $e2.admitted -or $e3.admitted -or $reenter1.admitted -or $status2.admitted
    if (-not $raced) {
        $ordering = [pscustomobject]@{
            CouponId = $couponId
            P1       = $e1.position
            P2       = $e2.position
            P3       = $e3.position
            Reenter1 = $reenter1.position
            Status2  = $status2.position
        }
        break
    }

    Write-Host "  (드레인과 경합했습니다. 새 쿠폰으로 다시 시도합니다 - $attempt/$MaxAttempts)" -ForegroundColor DarkGray
}

if ($null -eq $ordering) {
    Write-Host ""
    Write-Host "[순서 보장 / 진입 멱등성 / 상태 조회]" -ForegroundColor Yellow
    Write-Ng "$MaxAttempts 회 모두 드레인과 경합해 순번을 확인하지 못했습니다 (결함이 아니라 측정 실패입니다)"
    Write-Host "        통과 속도를 낮춰 다시 해보세요 - COUPON_WAITING_ROOM_ADMIT_PER_SECOND 를 1 로 두고" -ForegroundColor DarkGray
    Write-Host "        docker compose up -d coupon-service 로 컨테이너를 다시 만든 뒤 실행합니다." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "===== 대기실 검증: 실패 =====" -ForegroundColor Red
    exit 1
}

$couponId = $ordering.CouponId

Write-Host ""
Write-Host "[순서 보장] 먼저 온 사람이 앞 순번" -ForegroundColor Yellow
Test-Expected -Label 'user 1 순번' -Actual $ordering.P1 -Expected '1'
Test-Expected -Label 'user 2 순번' -Actual $ordering.P2 -Expected '2'
Test-Expected -Label 'user 3 순번' -Actual $ordering.P3 -Expected '3'

Write-Host ""
Write-Host "[진입 멱등성] 새로고침해도 순번 안 밀림" -ForegroundColor Yellow
Test-Expected -Label 'user 1 재진입 순번' -Actual $ordering.Reenter1 -Expected '1'

Write-Host ""
Write-Host "[상태 조회] 조회는 줄에 다시 세우지 않는다" -ForegroundColor Yellow
Test-Expected -Label 'user 2 상태 조회 순번' -Actual $ordering.Status2 -Expected '2'

Write-Host ""
Write-Host "[통과] 드레인(매초)이 앞에서부터 입장권을 발급" -ForegroundColor Yellow
Test-Expected -Label 'user 1 통과 여부' -Actual (Wait-Admitted -CouponId $couponId -UserId '1') -Expected 'true'

Write-Host ""
Write-Host "[통과 후 발급] 입장권이 있으면 발급 성공" -ForegroundColor Yellow
$issueStatus = Get-HttpStatus -Method Post -Uri "$BaseUrl/api/v1/coupons/$couponId/issue" `
    -Headers @{ 'X-User-Id' = '1' }
Test-Expected -Label 'user 1 발급 응답' -Actual $issueStatus -Expected '200'

Write-Host ""
Write-Host "[게이트] 대기실을 안 거친 사용자는 발급 차단" -ForegroundColor Yellow
$blockedStatus = Get-HttpStatus -Method Post -Uri "$BaseUrl/api/v1/coupons/$couponId/issue" `
    -Headers @{ 'X-User-Id' = '99999' }
Test-Expected -Label '입장권 없는 발급' -Actual $blockedStatus -Expected '403'

Write-Host ""
if ($script:Fail -eq 0) {
    Write-Host "===== 대기실 검증: 모두 통과 =====" -ForegroundColor Green
    exit 0
}

Write-Host "===== 대기실 검증: 실패 =====" -ForegroundColor Red
exit 1
