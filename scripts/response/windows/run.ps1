#Requires -Version 5.1
<#
.SYNOPSIS
    응답시간(P99) 측정 한 사이클: 쿼리 로그 끄기 -> [워밍업 라운드] -> 본 측정 라운드.

.DESCRIPTION
    scripts/response/run.sh 의 Windows 판본. 부하 조건은 bash 원본과 같다.

    한 라운드 = 리셋 -> 쿠폰 생성 -> k6(issue_burst) -> 검증.
    기본은 두 라운드다. 1회차는 버리는 워밍업이고 2회차가 측정값이다.

    핵심은 라운드 사이에 서비스 컨테이너를 건드리지 않는 것이다.
    JVM JIT, Hikari 풀, Lettuce 커넥션이 살아 있어야 2회차가 steady-state 가 된다.
    그래서 컨테이너를 만드는 일(로그 설정 적용)은 라운드 밖에서 딱 한 번만 하고,
    k6 실행에는 --no-deps 를 준다 (아래 "왜 --no-deps 인가").

    요약 JSON 은 build/k6/issue_burst-<이미지태그>-<회차>.json 에 남는다.

    사전 조건: .\build-and-run.ps1 로 mysql, redis, coupon-service 가 떠 있어야 한다.
    지표 읽는 법은 scripts/response/windows/README.md 참고.

.EXAMPLE
    .\scripts\response\windows\run.ps1
    워밍업 1회 + 본 측정 1회 (기본)

.EXAMPLE
    .\scripts\response\windows\run.ps1 -Once
    한 회차만. 스크립트를 고치고 빨리 돌려볼 때 쓰고, 이 수치는 구현 비교에 쓰지 않는다.

.EXAMPLE
    .\scripts\response\windows\run.ps1 -KeepLogging
    쿼리 로그를 켠 채로 실행한다. 무슨 SQL 이 나가는지 봐야 할 때만.
    이 트랙은 응답시간 자체가 측정 대상이라 이때 나온 수치는 전부 버려야 한다.
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$KeepLogging
)

$ErrorActionPreference = 'Stop'

# scripts/response/windows -> 저장소 루트
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# compose 호출을 전부 같은 파일 조합으로 통일한다.
#
# 호출마다 -f 조합이 다르면 compose 가 보는 "원하는 설정" 과 실제 떠 있는 컨테이너의 설정이
# 어긋나고, 그 상태에서 compose 가 컨테이너를 재생성할 여지가 생긴다. 재생성되면 쿼리 로그가
# 다시 켜지고 JVM 이 식어서 워밍업이 통째로 무의미해진다.
$Compose = if ($KeepLogging) {
    @('compose')
}
else {
    @('compose', '-f', 'docker-compose.yml', '-f', 'docker-compose.loadtest.yml')
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        # k6 은 threshold 가 깨지면 0 이 아닌 코드로 끝난다. 그것이 정상인 단계가 있다.
        [int[]]$AllowExitCodes = @(0)
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan

    & $Body

    # docker 같은 네이티브 exe 는 $ErrorActionPreference 를 따르지 않는다. 종료 코드를 직접 본다.
    if ($AllowExitCodes -notcontains $LASTEXITCODE) {
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
            # 먼저 해석되는데, Docker Desktop 의 그 경로가 응답 없이 멈추는 경우가 있어
            # 연결이 실패가 아니라 타임아웃으로 끝난다 (IPv4 로 폴백하지도 못한다).
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

function Invoke-Round {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Round,     # 요약 파일명에 붙는다 (warmup / steady / once)
        [Parameter(Mandatory)][string]$ImageTag
    )

    Write-Host ""
    Write-Host "===== $Label =====" -ForegroundColor Magenta

    Invoke-Step "데이터 리셋" { & "$PSScriptRoot\reset.ps1" }

    Write-Host ""
    Write-Host "==> 쿠폰 생성" -ForegroundColor Cyan
    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    Write-Host "COUPON_ID=$couponId"

    $summaryName = "issue_burst-$ImageTag-$Round.json"

    # k6 은 threshold(p(99)<500)가 깨지면 exit 99 를 낸다. 동기 구현에서는 깨지는 것이
    # 정상이고, 그게 이 트랙의 출발점이다. 여기서 멈추면 검증까지 못 간다.
    # 다만 exit 99 를 판정 근거로 쓰지는 않는다 — 아래 "threshold 판정" 블록 참고.
    #
    # 왜 --no-deps 인가
    #   k6 서비스에는 depends_on: coupon-service 가 걸려 있다. 그대로 두면 compose 가
    #   의존 서비스를 함께 다루면서 앱 컨테이너를 재생성할 여지가 생기고, 그러면 쿼리 로그가
    #   다시 켜지거나 JVM 이 식어 2회차 steady-state 가 무너진다.
    #   앱이 떠 있다는 것은 아래에서 Wait-AppReady 로 이미 보장했으므로 의존성이 필요 없다.
    Invoke-Step "k6 실행 (issue_burst, $ImageTag, $Round)" -AllowExitCodes 0, 99 -Body {
        docker @Compose run --rm --no-deps `
            -e COUPON_ID=$couponId `
            k6 run --summary-export "/out/$summaryName" `
            /scripts/response/windows/k6/issue_burst.js
    }

    $k6ExitCode = $LASTEXITCODE

    # ---------------------------------------------------------------------
    # threshold 판정 — 종료 코드가 아니라 방금 쓴 요약 JSON 을 읽는다
    #
    # k6 의 종료 코드만으로는 판정을 믿을 수 없다. p(99)=5.62ms, max=46.59ms 인 실행이
    # "thresholds have been crossed" 를 찍고 exit 99 로 끝난 적이 있다. 그 분포로는
    # 어떤 시점에도 500ms 를 넘길 수 없으므로 종료 코드 쪽이 틀린 것이다. 원인은 모른다.
    # (음수 duration 샘플(min < 0)을 의심했으나 아니었다 — 음수가 섞였는데 exit 0 인 실행도 있다.)
    #
    # 요약 JSON 의 metrics.<이름>.thresholds 값은 "넘겼다(true) / 통과(false)" 다.
    # lua-pool(p(99)=705ms)이 true, queue-mem/async(5.6ms)가 false 인 것으로 확인했다.
    # ---------------------------------------------------------------------
    $summaryPath = Join-Path 'build\k6' $summaryName
    $crossed = @()
    $summaryRead = $false

    if (Test-Path -LiteralPath $summaryPath) {
        try {
            $thresholds = (Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json).metrics.issue_latency.thresholds
            if ($thresholds) {
                $crossed = @($thresholds.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
                $summaryRead = $true
            }
        }
        catch {
            # 판정을 못 읽는다고 측정을 막지는 않는다. 수치 자체는 화면에 이미 나와 있다.
            Write-Host "  (요약 JSON 을 읽지 못해 threshold 판정을 건너뜁니다: $($_.Exception.Message))" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    if (-not $summaryRead) {
        Write-Host "threshold 판정: 확인 불가 (요약 JSON 없음)" -ForegroundColor DarkGray
    }
    elseif ($crossed.Count -gt 0) {
        Write-Host "threshold 미달: $($crossed -join ', ')" -ForegroundColor Yellow
        Write-Host "  동기 구현에서는 예상된 결과입니다. 측정값은 그대로 읽고 진행합니다." -ForegroundColor DarkGray
    }
    else {
        Write-Host "threshold 통과" -ForegroundColor Green

        # 여기가 이 블록을 만든 이유다. 둘이 어긋나면 요약 JSON 쪽을 믿는다.
        if ($k6ExitCode -eq 99) {
            Write-Host "  주의: k6 은 exit 99(threshold crossed)로 끝났는데 요약 JSON 은 통과입니다." -ForegroundColor Yellow
            Write-Host "        요약 JSON 을 신뢰하세요 (원인 미확정 — scripts\response\windows\README.md 3번)." -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "==> 검증" -ForegroundColor Cyan
    & "$PSScriptRoot\verify-burst.ps1" -CouponId $couponId

    Write-Host ""
    Write-Host "요약 JSON: build\k6\$summaryName" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 라운드 밖에서 딱 한 번 — 여기서만 컨테이너를 만든다
# ---------------------------------------------------------------------------
if ($KeepLogging) {
    Invoke-Step "쿼리 로그 켠 상태로 기동 (-KeepLogging)" {
        docker @Compose up -d coupon-service
    }
}
else {
    Invoke-Step "쿼리 로그 끄기" {
        docker @Compose up -d coupon-service
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
$containerId = (docker @Compose ps -q coupon-service | Select-Object -First 1)
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
    Write-Host "주의: 쿼리 로그가 켜져 있습니다. 이 트랙은 응답시간 자체가 측정 대상이라" -ForegroundColor Yellow
    Write-Host "      여기서 나온 p99 는 '로그 출력 대기 시간' 이지 발급 응답시간이 아닙니다." -ForegroundColor Yellow
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

# 어떤 구현을 쟀는지 남긴다. .env 가 아니라 실제로 떠 있는 컨테이너에서 읽는다.
$runningImage = docker inspect --format '{{.Config.Image}}' $containerId
$imageTag = ($runningImage -split ':')[-1]
if (-not $imageTag) { $imageTag = 'unknown' }

Write-Host "측정 대상 이미지: $runningImage" -ForegroundColor Green

# compose 가 ./build/k6 를 k6 컨테이너의 /out 으로 마운트한다. 없으면 만들어 둔다.
$outDir = Join-Path (Get-Location) 'build\k6'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# 라운드 사이에 컨테이너가 바뀌지 않았는지 나중에 대조하려고 지금 ID 를 잡아 둔다.
$containerIdBefore = $containerId

# ---------------------------------------------------------------------------
# 라운드
# ---------------------------------------------------------------------------
if ($Once) {
    Invoke-Round -Label "본 측정 1/1 (-Once, 워밍업 생략)" -Round 'once' -ImageTag $imageTag
}
else {
    Invoke-Round -Label "워밍업 1/2 (JIT, 커넥션풀 워밍 비용 흡수 — 이 수치는 버린다)" `
        -Round 'warmup' -ImageTag $imageTag
    Invoke-Round -Label "본 측정 2/2 (steady-state)" `
        -Round 'steady' -ImageTag $imageTag
}

# ---------------------------------------------------------------------------
# 워밍업이 유효했는지 확인
#
# 라운드 도중 앱 컨테이너가 재생성됐다면 2회차는 steady-state 가 아니다.
# 조용히 틀린 측정이 되는 자리라 끝나고 반드시 대조한다.
# ---------------------------------------------------------------------------
$containerIdAfter = (docker @Compose ps -q coupon-service | Select-Object -First 1)

Write-Host ""
if ($containerIdAfter -ne $containerIdBefore) {
    Write-Host "!! 측정 중에 coupon-service 컨테이너가 재생성됐습니다." -ForegroundColor Red
    Write-Host "   JVM 이 식었으므로 steady-state 수치로 쓸 수 없습니다." -ForegroundColor DarkGray
    Write-Host "   k6 실행에 --no-deps 가 빠지지 않았는지 확인하세요." -ForegroundColor DarkGray
}
elseif (-not $Once) {
    Write-Host "컨테이너 유지 확인 — 2회차는 steady-state 입니다." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "측정 대상: $runningImage" -ForegroundColor DarkGray
Write-Host "지표 읽는 법: scripts\response\windows\README.md" -ForegroundColor DarkGray
if (-not $KeepLogging) {
    Write-Host "개발 모드(쿼리 로그)로 돌아가려면: docker compose up -d coupon-service" -ForegroundColor DarkGray
}
