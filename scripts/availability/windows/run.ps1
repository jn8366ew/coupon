#Requires -Version 5.1
<#
.SYNOPSIS
    가용성(대기실) 트랙 러너. baseline / single / scale / verify / journey.

.DESCRIPTION
    scripts/availability/run.sh 의 Windows 판본. 부하 조건(rate, duration, 재고, 허용 오차)은
    bash 원본과 같다.

    모드
      baseline  대기실 없이 발급 API 로 직접 쏟아붓는다. 대기실 도입 전후를 비교하는 대조군.
      single    서버 1대. 대기실 진입 요청을 쏟아붓고 Redis 입장권이 초당 몇 개 나왔는지 센다.
      scale     서버 2대(coupon-service-2, --profile scale). 통과 속도가 서버 수와 무관한지 본다.
      verify    숫자 대신 기능 정오만 PASS/FAIL 로 (verify.ps1 위임).
      journey   진입 -> 폴링 -> 발급까지 실제 클라이언트 여정. 폴링이 만드는 추가 요청량을 본다.
      (인자 없이 실행하면 소스에 대기실 구현이 있으면 single, 없으면 baseline 이다.)

    원본과 다른 점 — 그대로 옮기면 조용히 틀리는 자리들
      - 게이트 경로가 com/apiece/... 가 아니라 com/example/... 다 (이 저장소의 패키지).
        원본 그대로면 모든 모드가 baseline 으로 떨어진다.
      - 입장권 스캔 패턴이 waiting:{id}:pass:* 가 아니라 waiting:{id}:pass* 다.
        실제 키에는 pass 와 userId 사이에 구분자가 없다 (WaitingRoomRedisRepository.passKey).
        원본 패턴으로는 항상 0건이 나와 single/scale 이 무조건 실패한다.
      - 발급/조회 경로가 /api/v1/... 다. 대기실만 /api/waiting-room 으로 v1 이 없다.
      - k6 이 컨테이너 안에서 도므로 BASES 는 호스트 포트가 아니라 compose 서비스 이름이다.
      - trap EXIT 대신 try/finally 로 coupon-service-2 를 내린다.

    이 트랙은 대기실이 들어간 새 태그로 빌드해야 성립한다. 러너는 빌드하지 않는다 —
    라운드에 들어가기 전에 기능이 있는지 직접 확인하고, 없으면 DB/Redis 를 건드리기 전에 멈춘다.

.EXAMPLE
    .\scripts\availability\windows\run.ps1
    소스 단계 자동 감지 (대기실이 있으면 single).

.EXAMPLE
    .\scripts\availability\windows\run.ps1 scale
    2번째 인스턴스를 띄워 전역 통과 속도가 유지되는지 본다.

.EXAMPLE
    .\scripts\availability\windows\run.ps1 journey -Users 200
    진입 -> 폴링 -> 발급 여정.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('auto', 'baseline', 'single', 'scale', 'verify', 'journey')]
    [string]$Mode = 'auto',

    [int]$Rate = 1000,
    [string]$Duration = '20s',
    [long]$Quantity = 1000000,

    # 컨테이너에 COUPON_WAITING_ROOM_* 가 붙어 있으면 그 값이 이긴다 (아래에서 덮어쓴다).
    # 여기 값은 환경변수가 없을 때의 fallback 이다 (application.yaml 기본값과 같다).
    [int]$AdmitPerSecond = 100,
    [long]$PassTtlMs = 30000,
    [int]$TolerancePercent = 30,

    # journey 전용
    [int]$Users = 200,

    [switch]$KeepLogging
)

$ErrorActionPreference = 'Stop'

# scripts/availability/windows -> 저장소 루트
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# 호스트에서 앱을 부를 때 쓰는 주소.
# localhost 가 아니라 127.0.0.1 — Windows 에서 localhost 는 IPv6 ::1 로 먼저 해석되는데
# Docker Desktop 의 그 경로가 응답 없이 멈추는 경우가 있다 (IPv4 로 폴백하지도 못한다).
$AppUrl = 'http://127.0.0.1:8080'
$SecondaryUrl = 'http://127.0.0.1:8081'

# compose 호출을 전부 같은 파일 조합으로 통일한다.
# 호출마다 -f 조합이 다르면 compose 가 보는 "원하는 설정" 과 실제 떠 있는 컨테이너의 설정이
# 어긋나고, 그 상태에서 compose 가 컨테이너를 재생성할 여지가 생긴다.
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
    param(
        [string]$Url = $AppUrl,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri "$Url/api/v1/users/me/issuances" `
                -Headers @{ 'X-User-Id' = '1' } -UseBasicParsing -TimeoutSec 5 | Out-Null
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    return $false
}

# 원본의 source_stage / require_source. 경로의 패키지가 com/example 인 것이 이 저장소다.
function Get-SourceStage {
    if (Test-Path -LiteralPath 'src/main/kotlin/com/example/coupon/application/RedisWaitingRoom.kt') {
        return 'part-6-1'
    }
    return 'part-6-0'
}

function Invoke-K6 {
    param(
        [Parameter(Mandatory)][string]$ScriptFile,     # k6/ 안의 파일명
        [Parameter(Mandatory)][string]$SummaryName,
        [Parameter(Mandatory)][hashtable]$EnvVars
    )

    $envArgs = @()
    foreach ($name in $EnvVars.Keys) {
        $envArgs += @('-e', "$name=$($EnvVars[$name])")
    }

    # k6 은 threshold 가 깨지면 exit 99 를 낸다. 여기서 멈추면 판정에 쓸 입장권 수와
    # 요약 JSON 을 못 읽으므로 99 는 통과시키고, 판정은 아래에서 따로 한다.
    #
    # --no-deps: k6 서비스에는 depends_on: coupon-service 가 걸려 있다. 그대로 두면 compose 가
    # 의존 서비스를 함께 다루면서 앱 컨테이너를 재생성할 여지가 생긴다 (scale 모드에서는
    # 2번째 인스턴스까지 흔들린다).
    Invoke-Step "k6 실행 ($ScriptFile)" -AllowExitCodes 0, 99 -Body {
        docker @Compose run --rm --no-deps @envArgs `
            k6 run --summary-export "/out/$SummaryName" `
            "/scripts/availability/windows/k6/$ScriptFile"
    }
}

# k6 의 종료 코드로 판정하지 않는다 (docs/architecture.md 7절의 exit 99 함정).
# 요약 JSON 을 읽어 지표를 직접 본다. 못 읽으면 $null 을 돌려주고 화면 수치로 대신한다.
function Read-K6Summary {
    param([Parameter(Mandatory)][string]$SummaryName)

    $path = Join-Path 'build\k6' $SummaryName
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
    }
    catch {
        Write-Host "  (요약 JSON 을 읽지 못했습니다: $($_.Exception.Message))" -ForegroundColor DarkGray
        return $null
    }
}

# 통과한 사람 수 = 살아 있는 입장권 키 수.
#
# 패턴에 주의. 실제 키는 waiting:{7}:pass12345 처럼 pass 와 userId 사이에 구분자가 없다
# (WaitingRoomRedisRepository.passKey). 원본의 waiting:{id}:pass:* 로는 한 건도 안 잡힌다.
# 문자열은 ${} 로 감싼다 — "waiting:{$CouponId}:..." 처럼 쓰면 뒤에 오는 콜론 때문에
# PowerShell 이 드라이브 한정 변수로 파싱할 여지가 생긴다.
function Get-PassCount {
    param([Parameter(Mandatory)][string]$CouponId)

    $pattern = "waiting:{${CouponId}}:pass*"
    $keys = docker @Compose exec -T redis redis-cli --scan --pattern $pattern

    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! redis-cli 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }

    return @($keys | Where-Object { $_ -match '\S' }).Count
}

# 2번째 인스턴스를 내린다.
#
# $ErrorActionPreference 를 잠깐 내리는 이유 — docker compose 는 진행 상황("Container …
# Stopping")을 stderr 로 쓴다. 2>&1 로 합치면 PowerShell 5.1 이 그것을 ErrorRecord 로 감싸고,
# 'Stop' 이면 NativeCommandError 로 올라온다. 정상 종료인데 화면에는 빨간 실패로 보인다.
# 출력을 버리려면 합쳐야 하므로, 이 호출 동안만 내렸다가 되돌린다.
function Stop-SecondInstance {
    param([switch]$Announce)

    if ($Announce) {
        Write-Host ""
        Write-Host "==> 2번째 인스턴스 정리 (coupon-service-2)" -ForegroundColor Cyan
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        docker @Compose --profile scale stop coupon-service-2 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# ---------------------------------------------------------------------------
# 모드 결정 — 소스에 구현이 있는지부터 본다 (원본 run.sh 의 source_stage / require_source)
# ---------------------------------------------------------------------------
$sourceStage = Get-SourceStage

if ($Mode -eq 'auto') {
    $Mode = if ($sourceStage -eq 'part-6-1') { 'single' } else { 'baseline' }
    Write-Host "모드 자동 감지: $Mode (소스 단계 $sourceStage)" -ForegroundColor DarkGray
}

if ($Mode -ne 'baseline' -and $sourceStage -ne 'part-6-1') {
    Write-Host "!! $Mode 은 part-6-1-waiting-room 이후에 실행할 수 있습니다." -ForegroundColor Red
    Write-Host "   src/main/kotlin/com/example/coupon/application/RedisWaitingRoom.kt 가 없습니다." -ForegroundColor DarkGray
    exit 1
}

# verify 는 숫자를 재지 않으므로 컨테이너 준비 절차를 타지 않고 바로 위임한다.
if ($Mode -eq 'verify') {
    & "$PSScriptRoot\verify.ps1" -BaseUrl $AppUrl -TotalQuantity $Quantity
    exit $LASTEXITCODE
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

$containerId = (docker @Compose ps -q coupon-service | Select-Object -First 1)
if (-not $containerId) {
    Write-Host "!! coupon-service 컨테이너를 찾을 수 없습니다." -ForegroundColor Red
    exit 1
}

$containerEnv = docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $containerId

if (-not $KeepLogging -and ($containerEnv -match 'SPRING_JPA_SHOW_SQL=false').Count -eq 0) {
    Write-Host "!! 쿼리 로그를 껐는데 컨테이너에 반영되지 않았습니다." -ForegroundColor Red
    Write-Host "   이 상태로 측정하면 로그 출력 대기가 응답시간에 섞여 수치가 무의미해집니다." -ForegroundColor DarkGray
    Write-Host "   docker-compose.loadtest.yml 이 있는지, compose 가 컨테이너를" -ForegroundColor DarkGray
    Write-Host "   재생성했는지 확인하세요." -ForegroundColor DarkGray
    exit 1
}

# 통과 속도와 입장권 TTL 은 이 트랙 판정의 기준값이다. 파라미터 기본값을 믿지 않고
# 실제로 컨테이너에 붙은 값을 읽어 쓴다 (붙어 있지 않으면 파라미터 값이 곧 yaml 기본값이다).
function Get-ContainerEnvValue {
    param([Parameter(Mandatory)][string]$Name)

    $line = @($containerEnv) | Where-Object { $_ -like "$Name=*" } | Select-Object -First 1
    if ($line) { return ($line -split '=', 2)[1] }
    return $null
}

$admitFromEnv = Get-ContainerEnvValue 'COUPON_WAITING_ROOM_ADMIT_PER_SECOND'
$ttlFromEnv = Get-ContainerEnvValue 'COUPON_WAITING_ROOM_PASS_TTL_MS'
if ($admitFromEnv) { $AdmitPerSecond = [int]$admitFromEnv }
if ($ttlFromEnv) { $PassTtlMs = [long]$ttlFromEnv }

# 변수 뒤에 한글이 바로 붙으면 ${} 로 감싼다. PowerShell 은 한글을 식별자 문자로 보기 때문에
# "$AdmitPerSecond건" 을 그 이름의 변수 하나로 읽고, 없는 변수라 빈 문자열이 된다.
# 에러가 안 나고 숫자만 조용히 사라지는 자리다 (실제로 "통과 속도 = /s" 로 찍혔다).
Write-Host "통과 속도 = ${AdmitPerSecond}건/s, 입장권 TTL = ${PassTtlMs}ms" -ForegroundColor DarkGray

# 캐시 설정도 같이 남긴다. 이 트랙이 재는 값은 아니지만, journey 의 http_req_duration 을
# 읽을 때 이걸 모르면 오독한다 — p90/p95 의 100~150ms 는 대기실이 느린 게 아니라
# CouponIssuePolicyReader 가 캐시 미스마다 자는 시뮬레이션 지연이다.
# efficiency 트랙에서 같은 자리를 이미 한 번 밟았다 (회귀가 아니라 워크로드가 바뀐 것이었다).
foreach ($name in 'COUPON_CACHE_SIMULATED_LOAD_LATENCY_MS', 'COUPON_CACHE_TTL_MS') {
    $value = Get-ContainerEnvValue $name
    if (-not $value) { $value = '(미설정 — application.yaml 기본값)' }
    Write-Host "$name = $value" -ForegroundColor DarkGray
}

# 어떤 구현을 쟀는지 남긴다. .env 가 아니라 실제로 떠 있는 컨테이너에서 읽는다.
$runningImage = docker inspect --format '{{.Config.Image}}' $containerId
$imageTag = ($runningImage -split ':')[-1]
if (-not $imageTag) { $imageTag = 'unknown' }

Write-Host "측정 대상 이미지: $runningImage" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 이 모드가 이 이미지에서 성립하는지 확인한다 — 라운드보다 앞이라 DB/Redis 를 건드리기 전이다
#
# 기대 방향이 모드마다 반대다.
#   single/scale/journey — 대기실이 있어야 한다. 없으면 k6 이 20초 동안 404 만 받는다.
#   baseline            — 대기실이 없어야 한다. "대기실을 붙이기 전" 을 재는 대조군이라
#                         게이트(CouponController 의 isAdmitted 검사)가 켜져 있으면 성립하지 않는다.
#
# 두 번째가 실제로 터졌다. waiting-room 이미지에서 baseline 을 돌렸더니 20,001건이 전부
# 403(NO_WAITING_ROOM_PASS)이었는데, 러너는 그걸 판정하지 않고 http_reqs 를 결과처럼 찍었다.
# 발급 0건 / 재고 그대로였으니 잰 것은 처리량이 아니라 게이트가 거절하는 속도였다.
# 에러로 죽지 않고 그럴듯한 숫자가 나오는 것이 이 자리의 위험이다.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> 측정 가능 여부 확인 (POST /api/waiting-room)" -ForegroundColor Cyan

$waitingRoomPresent = $false
try {
    # $ErrorActionPreference='Stop' 이라 404 는 예외로 온다.
    # 존재하지 않는 쿠폰 번호를 쓴다 — 진입은 Redis 만 건드리므로 200 이 정상이고,
    # 이때 생기는 waiting:{999999}:queue 는 바로 다음 리셋의 FLUSHALL 이 지운다.
    $probe = Invoke-RestMethod -Method Post -Uri "$AppUrl/api/waiting-room/999999" `
        -Headers @{ 'X-User-Id' = '1' } -TimeoutSec 5
    $waitingRoomPresent = ($null -ne $probe.PSObject.Properties['admitted'])
}
catch { }

if ($Mode -eq 'baseline') {
    if ($waitingRoomPresent) {
        Write-Host "!! 지금 떠 있는 이미지에는 대기실이 들어 있습니다 ($runningImage)." -ForegroundColor Red
        Write-Host "   baseline 은 '대기실이 없던 상태' 를 재는 대조군이라 이 이미지로는 잴 수 없습니다." -ForegroundColor DarkGray
        Write-Host "   발급 요청이 전부 403(NO_WAITING_ROOM_PASS)으로 튕겨서, 처리량이 아니라" -ForegroundColor DarkGray
        Write-Host "   게이트가 거절하는 속도를 재게 됩니다." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "   대기실이 들어가기 전 태그로 띄운 뒤 다시 실행하세요:" -ForegroundColor DarkGray
        Write-Host "       docker images coupon-service                     # 태그 목록" -ForegroundColor Yellow
        Write-Host "       .\build-and-run.ps1 -Tag reconcile-v3 -NoBuild" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   끝나면 되돌립니다:" -ForegroundColor DarkGray
        Write-Host "       .\build-and-run.ps1 -Tag waiting-room -NoBuild" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "대기실 없음 확인됨 (대조군으로 성립)" -ForegroundColor DarkGray
}
else {
    if (-not $waitingRoomPresent) {
        Write-Host "!! 떠 있는 앱에 대기실 엔드포인트가 없습니다." -ForegroundColor Red
        Write-Host "   현재 이미지: $runningImage" -ForegroundColor DarkGray
        Write-Host "   이 트랙은 WaitingRoomController 가 들어간 새 빌드가 필요합니다:" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "       .\build-and-run.ps1 -Tag waiting-room" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   (예전 태그로 되돌아갈 때는 -NoBuild 를 반드시 붙입니다 — CLAUDE.md)" -ForegroundColor DarkGray

        # 태그를 골랐는데도 예전 이미지가 뜨는 경우가 있다. .env 와 실제를 대조해 알려준다.
        if (Test-Path -LiteralPath '.env') {
            $envTagLine = @(Get-Content -LiteralPath '.env') |
                Where-Object { $_ -like 'COUPON_IMAGE_TAG=*' } | Select-Object -First 1
            if ($envTagLine) {
                $envTag = ($envTagLine -split '=', 2)[1]
                if ($envTag -and $envTag -ne $imageTag) {
                    Write-Host ""
                    Write-Host "   .env 는 COUPON_IMAGE_TAG=$envTag 인데 실제로 뜬 것은 $runningImage 입니다." -ForegroundColor Yellow
                    Write-Host "   docker-compose.yml 의 coupon-service.image 가 태그를 읽지 않는 상태입니다." -ForegroundColor DarkGray
                    Write-Host "   image: coupon-service:`${COUPON_IMAGE_TAG:-latest} 로 되돌리거나," -ForegroundColor DarkGray
                    Write-Host "   이번 라운드만 .\build-and-run.ps1 -Tag latest 로 빌드하세요." -ForegroundColor DarkGray
                }
            }
        }
        exit 1
    }
    Write-Host "대기실 엔드포인트 확인됨" -ForegroundColor DarkGray
}


# compose 가 ./build/k6 를 k6 컨테이너의 /out 으로 마운트한다. 없으면 만들어 둔다.
$outDir = Join-Path (Get-Location) 'build\k6'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# 모드별 실행
# ---------------------------------------------------------------------------
function New-LoadCoupon {
    $couponId = & "$PSScriptRoot\create-coupon.ps1" -BaseUrl $AppUrl -TotalQuantity $Quantity
    if (-not $couponId) {
        Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red
        exit 1
    }
    Write-Host "쿠폰 $couponId 생성 (재고 $Quantity)" -ForegroundColor DarkGray
    return $couponId
}

# 초 단위 문자열만 받는다. duration 을 못 읽으면 통과 속도를 나눌 수 없다.
function Get-DurationSeconds {
    if ($Duration -notmatch '^[1-9][0-9]*s$') {
        Write-Host "!! Duration 은 20s 처럼 초 단위로 입력해야 합니다 (지금: $Duration)." -ForegroundColor Red
        exit 1
    }
    return [int]$Duration.Substring(0, $Duration.Length - 1)
}

function Invoke-BaselineMode {
    $script:SummaryName = "issue_flood-$imageTag.json"
    $summaryName = $script:SummaryName

    & "$PSScriptRoot\reset.ps1"
    $couponId = New-LoadCoupon

    Invoke-K6 -ScriptFile 'issue_flood.js' -SummaryName $summaryName -EnvVars @{
        COUPON_ID = $couponId
        RATE      = $Rate
        DURATION  = $Duration
    }

    $summary = Read-K6Summary -SummaryName $summaryName

    Write-Host ""
    Write-Host "===== part-6-0: 대기실 없는 발급 트래픽 급증 =====" -ForegroundColor Magenta
    if (-not $summary) {
        Write-Host "  요약 JSON 을 읽지 못해 자동 판정을 건너뜁니다. 위 k6 출력을 직접 보세요." -ForegroundColor Yellow
        return
    }

    $reqs = [int]$summary.metrics.http_reqs.count
    $failures = [int]$summary.metrics.issue_failures.count

    Write-Host ("  http_reqs      = {0}" -f $reqs)
    Write-Host ("  issue_failures = {0}" -f $failures)

    # 실패한 요청은 발급 API 에 "도달한" 것이 아니다. 숫자를 그냥 보여주면
    # 전부 튕긴 실행도 대조군처럼 읽힌다 — 실제로 한 번 그랬다(20,001건 전부 403).
    # CLAUDE.md: checks 가 100% 가 아니면 나머지 숫자는 읽지 않는다.
    Write-Host ""
    if ($reqs -gt 0 -and $failures -ge $reqs) {
        Write-Host "FAIL: 요청이 전부 실패했습니다. 이 실행은 대조군으로 쓸 수 없습니다." -ForegroundColor Red
        Write-Host "   발급 API 처리량이 아니라 '거절되는 속도' 를 잰 것입니다." -ForegroundColor DarkGray
        Write-Host "   DB 에 실제로 행이 생겼는지 보면 바로 드러납니다:" -ForegroundColor DarkGray
        Write-Host "       docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -t coupon -e 'SELECT COUNT(*) FROM issuance;'" -ForegroundColor Yellow
        $script:ExitCode = 1
        return
    }
    if ($failures -gt 0) {
        Write-Host "주의: 실패가 ${failures}건 섞여 있습니다. 그만큼은 발급 API 에 도달하지 못했습니다." -ForegroundColor Yellow
    }

    Write-Host "  http_reqs 가 대기실 없이 발급 API 까지 도착한 요청 수다." -ForegroundColor DarkGray
    Write-Host "  대기실을 켠 뒤 single 모드의 입장권 수와 나란히 놓고 본다." -ForegroundColor DarkGray
}

function Invoke-WaitingRoomMode {
    param([Parameter(Mandatory)][ValidateSet('single', 'scale')][string]$Which)

    $seconds = Get-DurationSeconds

    # 원본 run.sh 의 사전 조건 세 가지.
    if ($Rate -le $AdmitPerSecond) {
        Write-Host "!! Rate 는 통과 속도($AdmitPerSecond/s)보다 커야 합니다 (지금: $Rate)." -ForegroundColor Red
        Write-Host "   줄이 쌓이지 않으면 드레인이 통과 속도만큼 일하지 않습니다." -ForegroundColor DarkGray
        exit 1
    }
    if (($seconds * 1000) -ge $PassTtlMs) {
        Write-Host "!! Duration 은 입장권 TTL(${PassTtlMs}ms)보다 짧아야 합니다 (지금: $Duration)." -ForegroundColor Red
        Write-Host "   측정 도중 앞쪽 입장권이 만료되면 개수를 적게 세게 됩니다." -ForegroundColor DarkGray
        exit 1
    }

    $script:SummaryName = "waiting_room_flood-$imageTag-$Which.json"
    $summaryName = $script:SummaryName
    $servers = 1
    $bases = 'http://coupon-service:8080'

    try {
        if ($Which -eq 'scale') {
            Invoke-Step "2번째 인스턴스 기동 (coupon-service-2)" {
                docker @Compose --profile scale up -d --no-deps coupon-service-2
            }

            if (-not (Wait-AppReady -Url $SecondaryUrl)) {
                Write-Host "!! 2번째 인스턴스가 60초 안에 응답하지 않습니다 ($SecondaryUrl)." -ForegroundColor Red
                Write-Host "   docker compose logs coupon-service-2 로 확인하세요." -ForegroundColor DarkGray
                exit 1
            }

            $servers = 2
            # k6 은 컨테이너 안에서 도므로 호스트 포트(8081)가 아니라 서비스 이름으로 붙는다.
            $bases = 'http://coupon-service:8080,http://coupon-service-2:8080'
        }
        else {
            # 앞선 scale 실행이 남아 있으면 1대 측정이 아니게 된다. 조용히 내린다.
            Stop-SecondInstance
        }

        Write-Host ""
        Write-Host "===== part-6-1: 서버 $servers 대의 전역 통과 속도 =====" -ForegroundColor Magenta

        & "$PSScriptRoot\reset.ps1"
        $couponId = New-LoadCoupon

        Invoke-K6 -ScriptFile 'waiting_room_flood.js' -SummaryName $summaryName -EnvVars @{
            COUPON_ID = $couponId
            BASES     = $bases
            RATE      = $Rate
            DURATION  = $Duration
        }

        # 판정은 k6 이 아니라 Redis 다. 입장권 TTL 안에 세야 하므로 k6 직후에 바로 센다.
        $admitted = Get-PassCount -CouponId $couponId
        $measured = [math]::Floor($admitted / $seconds)
        $lower = [math]::Floor($AdmitPerSecond * (100 - $TolerancePercent) / 100)
        $upper = [math]::Ceiling($AdmitPerSecond * (100 + $TolerancePercent) / 100)

        $summary = Read-K6Summary -SummaryName $summaryName

        Write-Host ""
        $enterFailures = 0
        if ($summary) {
            $enterFailures = [int]$summary.metrics.waiting_room_enter_failures.count
            Write-Host ("  진입 요청(http_reqs) = {0}" -f $summary.metrics.http_reqs.count)
            Write-Host ("  진입 실패            = {0}" -f $enterFailures)
        }
        Write-Host ("  Redis 입장권         = {0}건, 약 {1}건/s ({2}초)" -f $admitted, $measured, $seconds)

        # 진입이 실패하면 줄이 안 쌓이고, 그러면 입장권 수는 "통과 속도" 가 아니라
        # "줄에 들어간 사람 수" 의 상한에 걸린다. 아래 판정보다 이 줄을 먼저 읽어야 한다.
        if ($enterFailures -gt 0) {
            Write-Host ""
            Write-Host "주의: 진입이 ${enterFailures}건 실패했습니다. 줄이 덜 쌓였을 수 있어" -ForegroundColor Yellow
            Write-Host "      아래 판정을 통과 속도로 읽기 전에 원인을 먼저 보세요." -ForegroundColor DarkGray
        }

        # 아래 문자열의 ${} 는 생략하면 안 된다 — "$upper건" 은 그 이름의 변수 하나로 읽혀
        # 숫자가 조용히 사라진다 (한글이 PowerShell 식별자 문자다).
        Write-Host ""
        if ($measured -ge $lower -and $measured -le $upper) {
            if ($Which -eq 'scale') {
                Write-Host "PASS: 서버 2대에서도 전역 통과 속도가 유지됩니다 (${measured}건/s, 허용 ${lower}~${upper}건/s)" -ForegroundColor Green
            }
            else {
                Write-Host "PASS: 서버 1대 기준선 ${measured}건/s (허용 ${lower}~${upper}건/s)" -ForegroundColor Green
            }
        }
        else {
            Write-Host "FAIL: 기대 ${AdmitPerSecond}건/s, 허용 ${lower}~${upper}건/s 인데 ${measured}건/s 입니다" -ForegroundColor Red
            if ($admitted -eq 0) {
                Write-Host "   입장권이 한 건도 없습니다. 드레인 스케줄러(RedisWaitingRoom.drain)가 도는지," -ForegroundColor DarkGray
                Write-Host "   docker compose logs coupon-service 로 확인하세요." -ForegroundColor DarkGray
            }
            $script:ExitCode = 1
        }

        # scale 판정이 성립하려면 두 인스턴스에 실제로 요청이 갔어야 한다.
        # waiting_room_flood.js 는 BASES[__VU % BASES.length] 로 VU 단위 라운드로빈을 하므로,
        # 부하가 가벼워 k6 이 VU 를 1개만 쓰면 전 요청이 한 대로만 간다. 그래도 통과 속도는
        # 100/s 라 PASS 가 찍힌다 — 구현이 맞아서가 아니라 측정이 2대를 안 건드린 것이다.
        if ($Which -eq 'scale' -and $summary) {
            $peakVus = [int]$summary.metrics.vus.max
            if ($peakVus -lt 2) {
                Write-Host ""
                Write-Host "   주의: 이번 실행의 VU 최대치가 ${peakVus} 라 사실상 1대만 때렸습니다." -ForegroundColor Yellow
                Write-Host "         2대 판정으로 읽지 마세요 (VU 가 2 이상이어야 두 인스턴스로 갈립니다)." -ForegroundColor DarkGray
            }
            else {
                Write-Host ("  VU 최대치 {0} — 두 인스턴스로 갈렸습니다" -f $peakVus) -ForegroundColor DarkGray
            }
        }
    }
    finally {
        if ($Which -eq 'scale') {
            Stop-SecondInstance -Announce
        }
    }

}

function Invoke-JourneyMode {
    $script:SummaryName = "waiting_room_journey-$imageTag.json"
    $summaryName = $script:SummaryName

    & "$PSScriptRoot\reset.ps1"
    $couponId = New-LoadCoupon

    Invoke-K6 -ScriptFile 'waiting_room_journey.js' -SummaryName $summaryName -EnvVars @{
        COUPON_ID             = $couponId
        USERS                 = $Users
        POLL_INTERVAL_SECONDS = 1
        POLL_JITTER_SECONDS   = 0.25
        MAX_WAIT_SECONDS      = 30
    }

    Write-Host ""
    Write-Host "===== part-6-1: 클라이언트 여정 (진입 -> 폴링 -> 발급) =====" -ForegroundColor Magenta

    $summary = Read-K6Summary -SummaryName $summaryName
    if (-not $summary) {
        Write-Host "  요약 JSON 을 읽지 못해 자동 판정을 건너뜁니다. 위 k6 출력을 직접 보세요." -ForegroundColor Yellow
        }

    $m = $summary.metrics
    $failures = [int]$m.journey_failures.count
    $issued = [int]$m.journey_issued_users.count

    Write-Host ("  통과 후 발급 성공     = {0} / {1}명" -f $issued, $Users)
    Write-Host ("  실패(journey_failures) = {0}" -f $failures)
    Write-Host ("  상태 폴링 총 요청      = {0}" -f [int]$m.journey_status_polls.count)
    Write-Host ("  1인당 폴링 횟수        = 평균 {0:N1}, 최대 {1:N0}" -f $m.journey_polls_per_user.avg, $m.journey_polls_per_user.max)
    Write-Host ("  대기 시간(ms)          = 평균 {0:N0}, p95 {1:N0}" -f $m.journey_waiting_time.avg, $m.journey_waiting_time.'p(95)')

    Write-Host ""
    # 판정은 종료 코드가 아니라 이 지표로 한다 (docs/architecture.md 7절).
    if ($failures -eq 0 -and $issued -eq $Users) {
        Write-Host "PASS: $Users 명 전원이 대기실을 통과해 발급까지 마쳤습니다" -ForegroundColor Green
    }
    else {
        Write-Host "FAIL: 실패 $failures 건, 발급 $issued / $Users 명" -ForegroundColor Red
        Write-Host "   k6 출력의 console.error 줄에 어느 단계에서 깨졌는지 나옵니다." -ForegroundColor DarkGray
        $script:ExitCode = 1
    }

    Write-Host ""
    Write-Host "  폴링 총 요청 수가 이 방식의 비용이다 — 통과 속도를 올리면 줄고, 낮추면 늘어난다." -ForegroundColor DarkGray

}

$script:ExitCode = 0

switch ($Mode) {
    'baseline' { Invoke-BaselineMode }
    'single' { Invoke-WaitingRoomMode -Which 'single' }
    'scale' { Invoke-WaitingRoomMode -Which 'scale' }
    'journey' { Invoke-JourneyMode }
}

Write-Host ""
Write-Host "측정 대상: $runningImage" -ForegroundColor DarkGray
Write-Host "요약 JSON: build\k6\$($script:SummaryName)" -ForegroundColor DarkGray
Write-Host "읽는 법: scripts\availability\windows\README.md" -ForegroundColor DarkGray
if (-not $KeepLogging) {
    Write-Host "개발 모드(쿼리 로그)로 돌아가려면: docker compose up -d coupon-service" -ForegroundColor DarkGray
}

exit $script:ExitCode
