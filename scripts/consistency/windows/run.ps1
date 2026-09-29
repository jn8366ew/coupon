#Requires -Version 5.1
<#
.SYNOPSIS
    part-5 (정합성) 러너. 지금 단계를 감지해서 그 단계의 시나리오를 돌린다.

.DESCRIPTION
    scripts/consistency/run.sh 의 Windows 판본. 시나리오와 검증 기준은 bash 원본과 같다.

    part-5-0  불일치 주입   : force-dlt / force-db-only 를 각각 주입하고 drift 리포트를 본다
    part-5-1  DLT 재처리    : DLT 에 쌓인 메시지를 replay 해서 DB 에 되살아나는지 검증
    part-5-2  대사 자동보정 : Redis users 누락은 자동 보정, DB 측 불일치는 알람만인지 검증

    단계는 두 곳에서 읽는다.

        소스   : src/main/kotlin/com/example/coupon/... 에 해당 클래스 파일이 있는가
        런타임 : 떠 있는 앱에 해당 엔드포인트가 있는가

    둘이 어긋나면 "코드는 썼는데 이미지를 안 만들었다" 는 뜻이므로 아무것도 건드리지 않고 멈춘다.
    빌드는 여기서 하지 않는다 — 태그를 고르는 것은 사람이 할 일이고, 예전 태그로 되돌아갈 때
    -NoBuild 를 빼먹으면 그 이미지가 덮이기 때문이다 (CLAUDE.md).

    원본은 패키지가 com.apiece 이고 scripts/load/part-5/... 경로를 참조한다.
    이 저장소는 com.example 이고 트랙이 scripts/consistency 로 재편돼 있어 둘 다 바꿔 두었다.

    ! 이 트랙은 응답시간을 재지 않으므로 docker-compose.loadtest.yml(쿼리 로그 끄기)을 얹지 않는다.

.EXAMPLE
    .\scripts\consistency\windows\run.ps1
    단계를 자동 감지해서 돌린다. 지금은 part-5-0 (불일치 주입).

.EXAMPLE
    .\scripts\consistency\windows\run.ps1 -Stage part-5-0
    감지를 무시하고 그 단계를 돌린다. 강의를 따라가며 클래스 이름을 다르게 지어
    파일 기반 감지가 못 잡을 때 쓴다.

.EXAMPLE
    .\scripts\consistency\windows\run.ps1 -Count 3
    주입 건수를 바꾼다 (기본 10).
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'part-5-0', 'part-5-1', 'part-5-2')]
    [string]$Stage = 'auto',
    [int]$Count = 10
)

$ErrorActionPreference = 'Stop'

# scripts/consistency/windows -> 저장소 루트
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# 호스트에서 앱을 부를 때 쓰는 주소.
# localhost 가 아니라 127.0.0.1 — Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
# Docker Desktop 의 그 경로가 응답 없이 멈추는 경우가 있다 (IPv4 로 폴백하지도 못한다).
$AppUrl = 'http://127.0.0.1:8080'

# 원본 _common.sh 의 fail 변수. PowerShell 함수 안에서 쓰려면 script 스코프여야 한다.
$script:Fail = 0

# ---------------------------------------------------------------------------
# _common.sh 에 있던 헬퍼들 — 별도 파일로 빼지 않고 여기 인라인한다.
# 이 저장소에는 _common.ps1 선례가 없고(트랙마다 일부러 복제한다),
# 원본에서도 _common.sh 를 쓰는 것은 run.sh 하나뿐이다.
# ---------------------------------------------------------------------------

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan

    & $Body

    # docker 같은 네이티브 exe 는 $ErrorActionPreference 를 따르지 않는다. 종료 코드를 직접 본다.
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "!! 실패: $Name (exit code $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

# 원본 wait_service_ready. /metrics/cache 는 part-4 에서 들어온 것이라 이 트랙의 모든 단계에 있다.
function Wait-AppReady {
    param([int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Method Get -Uri "$AppUrl/metrics/cache" -TimeoutSec 5 | Out-Null
            return $true
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }

    return $false
}

function Invoke-MysqlScalar {
    param([Parameter(Mandatory)][string]$Sql)

    $out = docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e $Sql
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! MySQL 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }

    $line = ($out | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    if ($null -eq $line) { return '' }
    return $line.Trim()
}

function Invoke-RedisCli {
    $out = (docker compose exec -T redis redis-cli @args | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! redis-cli 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    return $out
}

# 원본은 색 있는 ✓ / ✗ 를 쓰지만 CP949 콘솔에서 물음표로 깨진다.
# 이 저장소의 다른 검증 스크립트(verify.ps1)와 같은 PASS / FAIL 표기를 쓴다.
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

function Write-Summary {
    param([Parameter(Mandatory)][string]$StageName)

    Write-Host ""
    if ($script:Fail -eq 0) {
        Write-Host "===== $StageName 검증: 모두 통과 =====" -ForegroundColor Green
        exit 0
    }

    Write-Host "===== $StageName 검증: 실패 =====" -ForegroundColor Red
    exit 1
}

function Get-ContainerEnv {
    $id = (docker compose ps -q coupon-service | Select-Object -First 1)
    if (-not $id) { return @() }
    return @(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $id)
}

# 설정을 바꿨으면 적용됐는지 먼저 확인한다 (docs/architecture.md 7).
# docker-compose.yml 의 environment 에 선언이 없는 이름은 셸 변수로 줘도 컨테이너에 안 붙는다.
function Assert-EnvApplied {
    param([Parameter(Mandatory)][string]$Name)

    $line = Get-ContainerEnv | Where-Object { $_ -like "$Name=*" } | Select-Object -First 1
    if ($line) {
        Write-Host "  $($line.Trim())" -ForegroundColor DarkGray
        return
    }

    Write-Host "  주의: $Name 이 컨테이너에 붙지 않았습니다." -ForegroundColor Yellow
    Write-Host "        docker-compose.yml 의 coupon-service.environment 에 다음 줄이 필요합니다:" -ForegroundColor DarkGray
    Write-Host "          ${Name}: `${$Name}" -ForegroundColor DarkGray
    Write-Host "        (없으면 셸 환경변수는 조용히 무시되고 앱은 기본값으로 돕니다.)" -ForegroundColor DarkGray
}

# 원본 restart_service. kafka 를 먼저 재생성하는 것은 단계 사이에 토픽을 깨끗이 하기 위해서다.
# 볼륨이 없어서 --force-recreate 하면 토픽과 오프셋이 통째로 사라진다 — 의도된 동작이다.
function Restart-CouponService {
    param([int]$ReconcileIntervalMs = 0)

    Invoke-Step "kafka 재생성 (토픽/오프셋이 사라집니다)" {
        docker compose up -d --force-recreate kafka
    }

    Write-Host "kafka healthy 대기..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $status = (docker compose ps kafka --format '{{.Status}}' | Out-String).Trim()
        if ($status -like '*healthy*') { break }
        Start-Sleep -Seconds 1
    }

    if ($ReconcileIntervalMs -gt 0) {
        $env:COUPON_RECONCILE_INTERVAL_MS = "$ReconcileIntervalMs"
        Invoke-Step "coupon-service 재생성 (COUPON_RECONCILE_INTERVAL_MS=$ReconcileIntervalMs)" {
            docker compose up -d --force-recreate coupon-service
        }
    }
    else {
        Invoke-Step "coupon-service 재기동" { docker compose restart coupon-service }
    }

    if (-not (Wait-AppReady)) {
        Write-Host "!! coupon-service 재기동 실패 (60초 안에 응답 없음)." -ForegroundColor Red
        Write-Host "   docker compose logs coupon-service 로 확인하세요." -ForegroundColor DarkGray
        exit 1
    }

    if ($ReconcileIntervalMs -gt 0) { Assert-EnvApplied 'COUPON_RECONCILE_INTERVAL_MS' }
    if ($env:COUPON_RECONCILE_AUDIT_CRON) { Assert-EnvApplied 'COUPON_RECONCILE_AUDIT_CRON' }
}

# ---------------------------------------------------------------------------
# 단계 감지
# ---------------------------------------------------------------------------

function Get-SourceStage {
    # 원본은 com/apiece/... 를 본다. 이 저장소의 패키지는 com/example/... 다.
    if (Test-Path -LiteralPath 'src/main/kotlin/com/example/coupon/batch/Reconciler.kt') { return 'part-5-2' }
    if (Test-Path -LiteralPath 'src/main/kotlin/com/example/coupon/application/IssuanceDltService.kt') { return 'part-5-1' }
    return 'part-5-0'
}

function Get-RuntimeStage {
    try {
        Invoke-RestMethod -Method Get -Uri "$AppUrl/metrics/reconcile" -TimeoutSec 5 | Out-Null
        return 'part-5-2'
    }
    catch { }

    try {
        Invoke-RestMethod -Method Get -Uri "$AppUrl/admin/issuance/dlt" -TimeoutSec 5 | Out-Null
        return 'part-5-1'
    }
    catch { }

    return 'part-5-0'
}

# ---------------------------------------------------------------------------
# 시나리오
# ---------------------------------------------------------------------------

# part-5-0. 두 가지 불일치를 각각 주입하고 그때마다 리포트를 본다.
# 원본은 주입 스크립트 출력을 /dev/null 로 버리지만 여기서는 보여준다 —
# 하네스가 제대로 도는지 확인하는 것이 이 단계의 목적이기 때문이다.
function Invoke-Baseline {
    foreach ($injector in 'force-dlt.ps1', 'force-db-only.ps1') {
        & "$PSScriptRoot\reset.ps1"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        $couponId = & "$PSScriptRoot\create-coupon.ps1"
        if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }
        Write-Host "COUPON_ID=$couponId"

        & "$PSScriptRoot\$injector" -CouponId $couponId -Count $Count
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        & "$PSScriptRoot\drift-report.ps1" -CouponId $couponId
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    Write-Host ""
    Write-Host "===== part-5-0 불일치 주입 완료 =====" -ForegroundColor Green
}

# 원본 wait_dlt_id. DLT 로그가 적재될 때까지 최대 30초 기다리고 첫 항목의 id 를 돌려준다.
function Wait-DltId {
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $logs = Invoke-RestMethod -Method Get -Uri "$AppUrl/admin/issuance/dlt" -TimeoutSec 5
            $id = @($logs)[0].id
            if ($id) { return $id }
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Invoke-DltReplay {
    $userBase = 900000
    Restart-CouponService

    Write-Host ""
    Write-Host "##### DLT replay #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    & "$PSScriptRoot\force-dlt.ps1" -CouponId $couponId -Count 1 -UserBase $userBase
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $userId = $userBase + 1
    $dltId = Wait-DltId
    if (-not $dltId) {
        Write-Ng "DLT 로그 대기 실패"
        Write-Summary 'part-5-1'
    }

    Invoke-RestMethod -Method Post -Uri "$AppUrl/admin/issuance/dlt/replay" `
        -ContentType 'application/json' -Body (@{ ids = @($dltId) } | ConvertTo-Json -Compress) | Out-Null

    $issuedQuery = "SELECT COUNT(*) FROM issuance WHERE user_id=$userId AND coupon_id=$couponId"
    for ($i = 0; $i -lt 30; $i++) {
        if ((Invoke-MysqlScalar -Sql $issuedQuery) -eq '1') { break }
        Start-Sleep -Seconds 1
    }

    Test-Expected -Label '원래 발급으로 DB 저장' -Actual (Invoke-MysqlScalar -Sql $issuedQuery) -Expected '1'
    Test-Expected -Label 'DLT 로그 상태' `
        -Actual (Invoke-MysqlScalar -Sql "SELECT status FROM issuance_dlt_log WHERE id=$dltId") `
        -Expected 'REPLAYED'

    Write-Summary 'part-5-1'
}

function Invoke-Reconcile {
    # 스케줄 대사가 검증 도중에 끼어들지 않도록 크론을 사실상 꺼 둔다 (1월 1일 0시).
    $env:COUPON_RECONCILE_AUDIT_CRON = '0 0 0 1 1 *'
    Restart-CouponService -ReconcileIntervalMs 3600000

    Write-Host ""
    Write-Host "##### Redis users 누락 자동 보정 #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-RestMethod -Method Post -Uri "$AppUrl/metrics/reconcile/reset" | Out-Null

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    & "$PSScriptRoot\force-db-only.ps1" -CouponId $couponId -Count $Count
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-RestMethod -Method Post -Uri "$AppUrl/admin/reconcile/run" | Out-Null

    Test-Expected -Label '발급자 명단 복구' `
        -Actual (Invoke-RedisCli SCARD "coupon:${couponId}:users") -Expected "$Count"
    Test-Expected -Label '자동 보정 횟수' `
        -Actual "$((Invoke-RestMethod -Method Get -Uri "$AppUrl/metrics/reconcile").reconcileAutoFixTotal)" `
        -Expected '1'

    Write-Host ""
    Write-Host "##### DB 측 불일치는 알람만 #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-RestMethod -Method Post -Uri "$AppUrl/metrics/reconcile/reset" | Out-Null

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    & "$PSScriptRoot\force-dlt.ps1" -CouponId $couponId -Count $Count
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $stockBefore = Invoke-RedisCli GET "coupon:${couponId}:stock"

    Invoke-RestMethod -Method Post -Uri "$AppUrl/admin/reconcile/run" | Out-Null

    Test-Expected -Label 'DB 측 불일치 감지' `
        -Actual "$((Invoke-RestMethod -Method Get -Uri "$AppUrl/metrics/reconcile").redisDbDrift)" `
        -Expected "$Count"
    Test-Expected -Label 'Redis 재고 유지' `
        -Actual (Invoke-RedisCli GET "coupon:${couponId}:stock") -Expected $stockBefore

    Write-Summary 'part-5-2'
}

# ---------------------------------------------------------------------------
# 여기서부터 본체
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "==> 앱 기동 대기" -ForegroundColor Cyan
if (-not (Wait-AppReady)) {
    Write-Host "!! coupon-service 가 60초 안에 응답하지 않습니다 ($AppUrl/metrics/cache)." -ForegroundColor Red
    Write-Host "   docker compose ps / docker compose logs coupon-service 로 확인하세요." -ForegroundColor DarkGray
    exit 1
}
Write-Host "준비됨"

# 어떤 구현을 상대로 돌렸는지 남긴다. .env 가 아니라 실제로 떠 있는 컨테이너에서 읽는다.
$containerId = (docker compose ps -q coupon-service | Select-Object -First 1)
if (-not $containerId) {
    Write-Host "!! coupon-service 컨테이너를 찾을 수 없습니다." -ForegroundColor Red
    exit 1
}
$runningImage = docker inspect --format '{{.Config.Image}}' $containerId
Write-Host "대상 이미지: $runningImage" -ForegroundColor Green

$sourceStage  = Get-SourceStage
$runtimeStage = Get-RuntimeStage
Write-Host "단계 감지: 소스=$sourceStage, 런타임=$runtimeStage" -ForegroundColor DarkGray

if ($Stage -eq 'auto') {
    if ($sourceStage -ne $runtimeStage) {
        Write-Host ""
        Write-Host "!! 현재 소스는 $sourceStage 인데 떠 있는 coupon-service 는 $runtimeStage 입니다." -ForegroundColor Red
        Write-Host "   코드는 썼는데 그 코드가 든 이미지가 떠 있지 않다는 뜻입니다." -ForegroundColor DarkGray
        Write-Host "   새 태그로 빌드해서 띄우세요:" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "       .\build-and-run.ps1 -Tag <태그>" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   (예전 태그로 되돌아갈 때는 -NoBuild 를 반드시 붙입니다 — CLAUDE.md)" -ForegroundColor DarkGray
        Write-Host "   감지가 틀린 것이라면 -Stage 로 직접 지정할 수 있습니다." -ForegroundColor DarkGray
        exit 1
    }
    $resolved = $sourceStage
}
else {
    $resolved = $Stage
    if ($resolved -ne $runtimeStage) {
        Write-Host "주의: -Stage $resolved 로 강제했지만 떠 있는 앱은 $runtimeStage 로 보입니다." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "===== $resolved 실행 =====" -ForegroundColor Magenta

switch ($resolved) {
    'part-5-2' { Invoke-Reconcile }
    'part-5-1' { Invoke-DltReplay }
    'part-5-0' { Invoke-Baseline }
}
