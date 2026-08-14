#Requires -Version 5.1
<#
.SYNOPSIS
    부하 테스트 한 사이클: 쿼리 로그 끄기 -> 데이터 리셋 -> 쿠폰 생성 -> k6 -> 검증.

.DESCRIPTION
    k6 을 Windows 에 설치하지 않고 compose 의 k6 서비스(profile: load)로 돌린다.
    k6 컨테이너는 앱과 같은 도커 네트워크 안에서 http://coupon-service:8080 으로 직접
    붙으므로 Windows 의 localhost:8080 포트포워딩을 거치지 않는다.

    측정 전에 coupon-service 의 쿼리 로그를 끈다(docker-compose.loadtest.yml).
    로그를 켠 채로 재면 응답시간의 대부분이 로그 출력 대기라 성능 수치가 무의미해진다.
    끄는 것으로 끝내지 않고 컨테이너에 실제로 적용됐는지 확인한 뒤 진행한다.

    요약 JSON 은 build/k6/<시나리오>.json 에 남는다.

    사전 조건: .\build-and-run.ps1 로 mysql, coupon-service 가 떠 있어야 한다.
    자세한 내용은 docs/load-test-k6.md 참고.

.EXAMPLE
    .\scripts\windows\load-test.ps1 over_issuance
    과발급 검증 (재고만큼만 발급되어야 한다)

.EXAMPLE
    .\scripts\windows\load-test.ps1 duplicate_issuance
    중복발급 검증 (1인 1매만 발급되어야 한다)

.EXAMPLE
    .\scripts\windows\load-test.ps1 over_issuance -KeepLogging
    쿼리 로그를 켠 채로 실행한다. 무슨 SQL 이 나가는지 봐야 할 때만 쓰고,
    이때 나온 성능 수치는 브랜치 비교에 쓰지 않는다.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('over_issuance', 'duplicate_issuance')]
    [string]$Scenario,

    [switch]$KeepLogging
)

$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..')

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

# 앱이 요청을 받을 준비가 될 때까지 기다린다. 컨테이너를 재생성한 직후엔 기동에 몇 초 걸린다.
function Wait-AppReady {
    param([int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            # localhost 가 아니라 127.0.0.1 을 쓴다. Windows 에서 localhost 는 IPv6 ::1 로
            # 먼저 해석되는데, Docker Desktop 의 ::1 경로가 응답 없이 멈추는 경우가 있어
            # 연결이 실패가 아니라 타임아웃으로 끝난다 (IPv4 로 폴백하지도 못한다).
            #
            # 조회 엔드포인트라 부작용이 없다. 200 이면 디스패처까지 살아있다는 뜻.
            Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/v1/users/me/issuances' `
                -Headers @{ 'X-User-Id' = '1' } -UseBasicParsing -TimeoutSec 5 | Out-Null
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
# 0) 쿼리 로그 설정을 확정한다
#
# 이 단계를 사람 손에 맡기면(=README 에 "먼저 이 명령을 치세요" 라고만 적으면) 언젠가
# 빼먹고, 빼먹어도 테스트는 멀쩡히 돌아가면서 틀린 수치만 남는다. 그래서 스크립트가
# 매번 상태를 확정하고, 확정됐는지 컨테이너에서 직접 확인한다.
# ---------------------------------------------------------------------------
if ($KeepLogging) {
    Invoke-Step "쿼리 로그 켠 상태로 기동 (-KeepLogging)" {
        docker compose up -d coupon-service
    }
}
else {
    Invoke-Step "쿼리 로그 끄기" {
        docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d coupon-service
    }
}

Write-Host ""
Write-Host "==> 앱 기동 대기" -ForegroundColor Cyan
if (-not (Wait-AppReady)) {
    Write-Host "!! 앱이 60초 안에 응답하지 않습니다." -ForegroundColor Red
    Write-Host "   docker compose logs coupon-service 로 확인하세요." -ForegroundColor DarkGray
    exit 1
}
Write-Host "준비됨"

# 설정이 실제로 컨테이너에 붙었는지 확인한다. "껐다고 생각했는데 안 꺼진" 상태로
# 측정하는 것이 최악이므로, 애매하면 진행하지 않고 멈춘다.
$containerId = (docker compose ps -q coupon-service | Select-Object -First 1)
if (-not $containerId) {
    Write-Host "!! coupon-service 컨테이너를 찾을 수 없습니다." -ForegroundColor Red
    exit 1
}

$containerEnv = docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $containerId
$loggingOff = ($containerEnv -match 'SPRING_JPA_SHOW_SQL=false').Count -gt 0

if ($KeepLogging) {
    if ($loggingOff) {
        Write-Host "!! -KeepLogging 인데 로그가 꺼진 상태입니다. 컨테이너 재생성에 실패했습니다." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "주의: 쿼리 로그가 켜져 있습니다. 응답시간·처리량 수치는 로그 대기 시간이" -ForegroundColor Yellow
    Write-Host "      섞여 있어 브랜치 비교에 쓸 수 없습니다. 정확성 지표(FAIL/OK)만 유효합니다." -ForegroundColor Yellow
}
else {
    if (-not $loggingOff) {
        Write-Host "!! 쿼리 로그를 껐는데 컨테이너에 반영되지 않았습니다." -ForegroundColor Red
        Write-Host "   이 상태로 측정하면 로그 출력 대기가 응답시간에 섞여 수치가 무의미해집니다." -ForegroundColor DarkGray
        Write-Host "   docker-compose.loadtest.yml 이 있는지, compose 가 컨테이너를" -ForegroundColor DarkGray
        Write-Host "   재생성했는지 확인하세요." -ForegroundColor DarkGray
        exit 1
    }
    Write-Host "쿼리 로그 꺼짐 확인 (SPRING_JPA_SHOW_SQL=false)" -ForegroundColor DarkGray
}

# 어떤 구현을 쟀는지 남긴다. 이미지 태그로 naive / pessimistic 을 오가므로,
# 결과 파일만 보고 어느 쪽 수치인지 알 수 없으면 비교 자체가 의미를 잃는다.
# (무엇을 띄울지는 build-and-run 이 정한다. 여기서는 확인만 하고 빌드하지 않는다.)
$runningImage = docker inspect --format '{{.Config.Image}}' $containerId
$imageTag = ($runningImage -split ':')[-1]
if (-not $imageTag) { $imageTag = 'unknown' }

Write-Host "측정 대상 이미지: $runningImage" -ForegroundColor Green

# compose 가 ./build/k6 를 k6 컨테이너의 /out 으로 마운트한다. 없으면 만들어 둔다.
$outDir = Join-Path (Get-Location) 'build\k6'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Invoke-Step "데이터 리셋" { & "$PSScriptRoot\reset.ps1" }

Write-Host ""
Write-Host "==> 쿠폰 생성" -ForegroundColor Cyan
$couponId = & "$PSScriptRoot\create-coupon.ps1"
Write-Host "COUPON_ID=$couponId"

# 요약 파일명에 이미지 태그를 넣어 구현별 결과가 서로 덮어쓰지 않게 한다.
$summaryName = "$Scenario-$imageTag.json"

Invoke-Step "k6 실행 ($Scenario, $imageTag)" {
    docker compose run --rm `
        -e COUPON_ID=$couponId `
        k6 run --summary-export "/out/$summaryName" "/scripts/$Scenario.js"
}

# coupon.issued_quantity 는 요청마다 올리지 않고 Redis 재고에서 파생시켜 주기적으로 반영한다
# (IssuedQuantitySynchronizer, 1초 주기). 부하가 끝나자마자 재면 아직 따라오지 못한 값을 보고
# count_match 가 FAIL 로 뜬다. 결함이 아니라 측정 시점 문제이므로 한 주기 이상 기다린다.
Write-Host ""
Write-Host "==> 카운터 동기화 대기 (3초)" -ForegroundColor Cyan
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "==> 검증" -ForegroundColor Cyan
& "$PSScriptRoot\verify.ps1" -CouponId $couponId

Write-Host ""
Write-Host "측정 대상: $runningImage" -ForegroundColor DarkGray
Write-Host "요약 JSON: build\k6\$summaryName" -ForegroundColor DarkGray
Write-Host "지표 읽는 법: docs\load-test-k6.md" -ForegroundColor DarkGray
if (-not $KeepLogging) {
    Write-Host "개발 모드(쿼리 로그)로 돌아가려면: docker compose up -d coupon-service" -ForegroundColor DarkGray
}
