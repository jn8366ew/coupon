#Requires -Version 5.1
<#
.SYNOPSIS
    part-4 (캐시 stampede / 매진 시그널) 측정 러너. 쿼리 로그 끄기 -> [워밍업 라운드] -> 본 측정 라운드.

.DESCRIPTION
    scripts/efficiency/run.sh 의 Windows 판본. 부하 조건은 bash 원본과 같다.

    시나리오 ① policy  : 발급 API 의 쿠폰 정보 조회 요청 급증 (coupon_burst.js)
    시나리오 ② sellout : 매진 후 새로고침 폭주 (post_sellout_refresh.js)

    한 라운드 = 리셋 -> 쿠폰 생성 -> [매진] -> 카운터 리셋 -> k6 -> 카운터 읽기.
    기본은 두 라운드다. 1회차는 버리는 워밍업이고 2회차가 측정값이다.

    핵심은 라운드 사이에 서비스 컨테이너를 건드리지 않는 것이다.
    JVM JIT, Hikari 풀, Lettuce 커넥션이 살아 있어야 2회차가 steady-state 가 된다.
    그래서 컨테이너를 만드는 일(로그 설정 적용)은 라운드 밖에서 딱 한 번만 하고,
    k6 실행에는 --no-deps 를 준다 (k6 서비스의 depends_on: coupon-service 때문에
    compose 가 앱 컨테이너를 재생성할 여지가 있다).

    요약 JSON 은 build/k6/<시나리오>-<이미지태그>-<회차>.json 에 남는다.
    threshold 통과 여부는 자동 판정하지 않는다 — 요약 JSON 과 화면 수치를 눈으로 본다.
    (k6 의 종료 코드는 믿을 수 없다. scripts/response/windows/README.md 3번 참고.)

    사전 조건: 이 트랙에서 처음 들어온 CacheMetricsController 가 포함된 새 이미지가 떠 있어야 한다.

        .\build-and-run.ps1 -Tag cache-4-0

    예전 태그로는 /metrics/cache 가 없다. 이 스크립트는 라운드에 들어가기 전에 그것을 확인하고,
    없으면 DB/Redis 를 건드리기 전에 멈춘다. 빌드는 여기서 하지 않는다 — 태그를 고르는 것은
    사람이 할 일이고, 예전 태그로 되돌아갈 때 -NoBuild 를 빼먹으면 그 이미지가 덮이기 때문이다.

    지표 읽는 법은 scripts/efficiency/windows/README.md 참고.

.EXAMPLE
    .\scripts\efficiency\windows\run.ps1
    두 시나리오 모두. 각각 워밍업 1회 + 본 측정 1회.

.EXAMPLE
    .\scripts\efficiency\windows\run.ps1 -Scenario policy -Once
    시나리오 ① 만 한 회차. 스크립트를 고치고 빨리 돌려볼 때 쓰고, 이 수치는 구현 비교에 쓰지 않는다.
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'policy', 'sellout')]
    [string]$Scenario = 'all',
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

# scripts/efficiency/windows -> 저장소 루트
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# 호스트에서 앱을 부를 때 쓰는 주소.
# localhost 가 아니라 127.0.0.1 — Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
# Docker Desktop 의 그 경로가 응답 없이 멈추는 경우가 있다 (IPv4 로 폴백하지도 못한다).
$AppUrl = 'http://127.0.0.1:8080'

# compose 호출을 전부 같은 파일 조합으로 통일한다.
#
# 호출마다 -f 조합이 다르면 compose 가 보는 "원하는 설정" 과 실제 떠 있는 컨테이너의 설정이
# 어긋나고, 그 상태에서 compose 가 컨테이너를 재생성할 여지가 생긴다. 재생성되면 쿼리 로그가
# 다시 켜지고 JVM 이 식어서 워밍업이 통째로 무의미해진다.
$Compose = @('compose', '-f', 'docker-compose.yml', '-f', 'docker-compose.loadtest.yml')

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
            Invoke-WebRequest -Uri "$AppUrl/api/v1/users/me/issuances" `
                -Headers @{ 'X-User-Id' = '1' } -UseBasicParsing -TimeoutSec 5 | Out-Null
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    return $false
}

# /metrics/cache 카운터를 0 으로 되돌린다. k6 을 쏘기 직전에만 부른다.
function Reset-CacheMetrics {
    Invoke-RestMethod -Method Post -Uri "$AppUrl/metrics/cache/reset" | Out-Null
}

# 이 트랙의 결과물. couponDbReads / couponCacheHits / soldOutRedisExists / soldOutFastPathHits.
function Show-CacheMetrics {
    $m = Invoke-RestMethod -Method Get -Uri "$AppUrl/metrics/cache"

    Write-Host ""
    Write-Host "카운터 (/metrics/cache)" -ForegroundColor Yellow
    Write-Host ("  couponDbReads        = {0}" -f $m.couponDbReads)
    Write-Host ("  couponCacheHits      = {0}" -f $m.couponCacheHits)
    Write-Host ("  soldOutRedisExists   = {0}" -f $m.soldOutRedisExists)
    Write-Host ("  soldOutFastPathHits  = {0}" -f $m.soldOutFastPathHits)
}

function Invoke-K6 {
    param(
        [Parameter(Mandatory)][string]$ScriptFile,   # k6/ 안의 파일명
        [Parameter(Mandatory)][string]$CouponId,
        [Parameter(Mandatory)][string]$SummaryName
    )

    # k6 은 threshold 가 깨지면 exit 99 를 낸다. 단계별 비교가 목적이라 깨지는 것이 정상인
    # 구간(4-0 ~ 4-1b)이 있고, 여기서 멈추면 카운터를 못 읽는다.
    Invoke-Step "k6 실행 ($ScriptFile)" -AllowExitCodes 0, 99 -Body {
        docker @Compose run --rm --no-deps `
            -e COUPON_ID=$CouponId `
            k6 run --summary-export "/out/$SummaryName" `
            "/scripts/efficiency/windows/k6/$ScriptFile"
    }
}

function Invoke-PolicyRound {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Round,
        [Parameter(Mandatory)][string]$ImageTag
    )

    Write-Host ""
    Write-Host "===== (1) 발급 API 쿠폰 정보 조회 요청 급증: $Label =====" -ForegroundColor Magenta

    Invoke-Step "데이터 리셋" { & "$PSScriptRoot\reset.ps1" }

    Write-Host ""
    Write-Host "==> 쿠폰 생성 (startsAt 미래, NotStarted 유도)" -ForegroundColor Cyan
    $couponId = & "$PSScriptRoot\create-issue-policy-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }
    Write-Host "COUPON_ID=$couponId"

    # 쿠폰 생성이 만든 조회까지 세지 않도록 k6 직전에 리셋한다.
    Reset-CacheMetrics

    $summaryName = "coupon_burst-$ImageTag-$Round.json"
    Invoke-K6 -ScriptFile 'coupon_burst.js' -CouponId $couponId -SummaryName $summaryName

    Show-CacheMetrics

    Write-Host ""
    Write-Host "요약 JSON: build\k6\$summaryName" -ForegroundColor DarkGray
}

function Invoke-SelloutRound {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Round,
        [Parameter(Mandatory)][string]$ImageTag
    )

    Write-Host ""
    Write-Host "===== (2) 매진 후 새로고침: $Label =====" -ForegroundColor Magenta

    Invoke-Step "데이터 리셋" { & "$PSScriptRoot\reset.ps1" }

    Write-Host ""
    Write-Host "==> 쿠폰 생성 (재고 100)" -ForegroundColor Cyan
    $couponId = & "$PSScriptRoot\create-small-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }
    Write-Host "COUPON_ID=$couponId"

    Invoke-Step "매진시키기" { & "$PSScriptRoot\sell-out.ps1" -CouponId $couponId }

    # 반드시 매진시킨 "뒤" 에 리셋한다. 순서가 바뀌면 sell-out 이 만든 100 건의
    # 쿠폰 조회가 couponDbReads 에 섞여 들어간다. (원본 bash 도 같은 순서다.)
    Reset-CacheMetrics

    $summaryName = "post_sellout_refresh-$ImageTag-$Round.json"
    Invoke-K6 -ScriptFile 'post_sellout_refresh.js' -CouponId $couponId -SummaryName $summaryName

    Show-CacheMetrics

    Write-Host ""
    Write-Host "요약 JSON: build\k6\$summaryName" -ForegroundColor DarkGray
}

function Invoke-Round {
    param(
        [Parameter(Mandatory)][ValidateSet('policy', 'sellout')][string]$Which,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Round,
        [Parameter(Mandatory)][string]$ImageTag
    )

    if ($Which -eq 'policy') { Invoke-PolicyRound  -Label $Label -Round $Round -ImageTag $ImageTag }
    else                     { Invoke-SelloutRound -Label $Label -Round $Round -ImageTag $ImageTag }
}

# 워밍업 1회 + 본 측정 1회 (-Once 면 1회). 원본 run.sh 와 같다.
#
# 라운드 목록을 배열에 담아 foreach 로 돌리지 않는다. PowerShell 은 문(statement)의 출력이
# 원소 하나면 그 하나를 꺼내 버리기 때문에, -Once 일 때 @(, @('라벨','once')) 가 통째로 풀려
# 문자열 두 개가 된다. 그러면 $r[0] 이 배열의 첫 원소가 아니라 문자열의 첫 글자가 되고,
# 라운드가 두 번 돌면서 요약 파일명이 "...-cache-4-0- .json" 처럼 나온다 — 실제로 그랬다.
function Invoke-Scenario {
    param(
        [Parameter(Mandatory)][ValidateSet('policy', 'sellout')][string]$Which,
        [Parameter(Mandatory)][string]$ImageTag
    )

    if ($Once) {
        Invoke-Round -Which $Which -ImageTag $ImageTag `
            -Label '본 측정 1/1 (-Once, 워밍업 생략)' -Round 'once'
    }
    else {
        Invoke-Round -Which $Which -ImageTag $ImageTag `
            -Label '워밍업 1/2 (JIT, 커넥션풀 워밍 비용 흡수 — 이 수치는 버린다)' -Round 'warmup'
        Invoke-Round -Which $Which -ImageTag $ImageTag `
            -Label '본 측정 2/2 (steady-state)' -Round 'steady'
    }
}

# ---------------------------------------------------------------------------
# 라운드 밖에서 딱 한 번 — 여기서만 컨테이너를 만든다
# ---------------------------------------------------------------------------
Invoke-Step "쿼리 로그 끄기" {
    docker @Compose up -d coupon-service
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
if (($containerEnv -match 'SPRING_JPA_SHOW_SQL=false').Count -eq 0) {
    Write-Host "!! 쿼리 로그를 껐는데 컨테이너에 반영되지 않았습니다." -ForegroundColor Red
    Write-Host "   이 상태로 측정하면 로그 출력 대기가 응답시간에 섞여 수치가 무의미해집니다." -ForegroundColor DarkGray
    Write-Host "   docker-compose.loadtest.yml 이 있는지, compose 가 컨테이너를" -ForegroundColor DarkGray
    Write-Host "   재생성했는지 확인하세요." -ForegroundColor DarkGray
    exit 1
}
Write-Host "쿼리 로그 꺼짐 확인 (SPRING_JPA_SHOW_SQL=false)" -ForegroundColor DarkGray

# 캐시 설정은 하네스가 강제하지 않는다 (docker-compose.yml 이 기본값을 준다).
# 이 두 값이 이 트랙 수치의 의미를 통째로 바꾸므로 어떤 조건에서 쟀는지 반드시 남긴다.
# 실제로 4-0 은 latency=0, 4-1 은 latency=100 에서 쟀는데 로그에 그게 없어서
# p99 가 1.45ms -> 102ms 로 "나빠진" 것처럼 보였다. 회귀가 아니라 워크로드가 바뀐 것이었다.
foreach ($name in 'COUPON_CACHE_TTL_MS', 'COUPON_CACHE_SIMULATED_LOAD_LATENCY_MS') {
    $line = @($containerEnv) | Where-Object { $_ -like "$name=*" } | Select-Object -First 1
    $value = if ($line) { ($line -split '=', 2)[1] } else { '(미설정 — application.yaml 기본값)' }
    Write-Host "$name = $value" -ForegroundColor DarkGray
}

# 어떤 구현을 쟀는지 남긴다. .env 가 아니라 실제로 떠 있는 컨테이너에서 읽는다.
$runningImage = docker inspect --format '{{.Config.Image}}' $containerId
$imageTag = ($runningImage -split ':')[-1]
if (-not $imageTag) { $imageTag = 'unknown' }

Write-Host "측정 대상 이미지: $runningImage" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 이 트랙이 이 이미지에서 성립하는지 확인한다 — 라운드보다 앞이라 DB/Redis 를 건드리기 전이다
#
# 카운터(/metrics/cache)는 이 트랙에서 처음 들어온 것이라 예전 태그의 이미지에는 없다.
# 확인하지 않으면 리셋과 쿠폰 생성을 다 해놓고 k6 직전 리셋 호출에서 404 로 죽는다 —
# 데이터는 이미 날아간 뒤인데 왜 죽었는지는 안 보이는, 제일 나쁜 순서다.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> 측정 가능 여부 확인 (/metrics/cache)" -ForegroundColor Cyan

$probeOk = $false
try {
    # $ErrorActionPreference='Stop' 이라 404 는 예외로 온다.
    $probe = Invoke-RestMethod -Method Get -Uri "$AppUrl/metrics/cache" -TimeoutSec 5
    # 200 이어도 응답이 딴 것일 수 있으니 필드까지 본다.
    $probeOk = ($null -ne $probe.couponDbReads)
}
catch { }

if (-not $probeOk) {
    Write-Host "!! 떠 있는 앱에 /metrics/cache 가 없습니다." -ForegroundColor Red
    Write-Host "   현재 이미지: $runningImage" -ForegroundColor DarkGray
    Write-Host "   이 트랙은 CacheMetricsController 가 들어간 새 빌드가 필요합니다:" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "       .\build-and-run.ps1 -Tag cache-4-0" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   (예전 태그로 되돌아갈 때는 -NoBuild 를 반드시 붙입니다 — CLAUDE.md)" -ForegroundColor DarkGray
    exit 1
}
Write-Host "카운터 엔드포인트 확인됨" -ForegroundColor DarkGray

# compose 가 ./build/k6 를 k6 컨테이너의 /out 으로 마운트한다. 없으면 만들어 둔다.
$outDir = Join-Path (Get-Location) 'build\k6'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# 시나리오
# ---------------------------------------------------------------------------
if ($Scenario -eq 'policy' -or $Scenario -eq 'all') {
    Invoke-Scenario -Which 'policy' -ImageTag $imageTag
}
if ($Scenario -eq 'sellout' -or $Scenario -eq 'all') {
    Invoke-Scenario -Which 'sellout' -ImageTag $imageTag
}

Write-Host ""
Write-Host "측정 대상: $runningImage" -ForegroundColor DarkGray
Write-Host "지표 읽는 법: scripts\efficiency\windows\README.md" -ForegroundColor DarkGray
Write-Host "개발 모드(쿼리 로그)로 돌아가려면: docker compose up -d coupon-service" -ForegroundColor DarkGray
