#Requires -Version 5.1
<#
.SYNOPSIS
    part-5 (정합성) 러너 — 개정된 scripts/consistency/run.sh 의 Windows 판본.

.DESCRIPTION
    run.ps1 은 강의 스크립트가 개정되기 "전" 판본의 포팅이다. 그 파일은 그대로 두고
    개정판을 이 파일로 새로 옮겼다. 시나리오와 검증 기준은 개정된 bash 원본과 같다.

    part-5-0  불일치 주입   : force-dlt / force-db-only 를 각각 주입하고 drift 리포트를 본다
    part-5-1  DLT 재처리    : DLT 에 쌓인 메시지를 replay 해서 DB 에 되살아나는지 검증
    part-5-2  대사 자동보정 : 대사 대상 등록 / Redis 누락 자동 보정 / DB 측은 알람만인지 검증

    개정판이 run.ps1 과 다른 점은 세 가지다.

        1. 대사 결과를 POST /admin/reconcile/run 의 "응답" 에서 읽는다.
           예전 판본은 GET /metrics/reconcile 의 누적 카운터를 읽었다. 그 엔드포인트는
           이제 필요 없다 — 방금 트리거한 실행의 결과가 곧 검증 대상이기 때문이다.
        2. 그래서 POST /metrics/reconcile/reset 도 사라졌다. 한 번의 실행 결과라 리셋할 게 없다.
        3. 런타임 단계 감지가 GET /admin/reconcile/run 의 405 를 본다.
           이 엔드포인트는 POST 전용이라 GET 하면 405 가 오는데, 그 405 자체가 라우트가
           있다는 증거다. 그리고 이 라우트는 Reconciler.kt 와 같은 시점에 생기므로
           소스 감지(파일 존재)와 런타임 감지가 같이 참이 된다 — 예전 판본에서 한 단계를
           다 쓰기 전까지 둘이 계속 어긋나던 문제가 원인부터 없어졌다.

    빌드는 여기서 하지 않는다 — 태그를 고르는 것은 사람이 할 일이고, 예전 태그로 되돌아갈 때
    -NoBuild 를 빼먹으면 그 이미지가 덮이기 때문이다 (CLAUDE.md).

    원본은 패키지가 com.apiece 이고 scripts/load/part-5/... 경로를 참조한다.
    이 저장소는 com.example 이고 트랙이 scripts/consistency 로 재편돼 있어 둘 다 바꿔 두었다.
    발급 경로도 원본의 /api/coupons 가 아니라 이 저장소의 /api/v1/coupons 다.

    ! 이 트랙은 응답시간을 재지 않으므로 docker-compose.loadtest.yml(쿼리 로그 끄기)을 얹지 않는다.

.EXAMPLE
    .\scripts\consistency\windows\run-v2.ps1
    단계를 자동 감지해서 돌린다.

.EXAMPLE
    .\scripts\consistency\windows\run-v2.ps1 -Stage part-5-1
    감지를 무시하고 그 단계를 돌린다. 강의를 따라가며 클래스 이름을 다르게 지어
    파일 기반 감지가 못 잡을 때 쓴다.

.EXAMPLE
    .\scripts\consistency\windows\run-v2.ps1 -Count 3
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

# 상태 코드만 필요할 때. 원본은 curl -w '%{http_code}' 로 간단히 끝나지만 PowerShell 은
# 4xx/5xx 에서 예외를 던지고, 코드를 꺼내는 방법이 5.1 과 7 에서 다르다.
# [int] 캐스팅은 양쪽(5.1 의 HttpStatusCode 열거형 / 7 의 값) 다 통한다.
function Get-HttpStatus {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get'
    )

    try {
        return [int](Invoke-WebRequest -Method $Method -Uri $Uri -TimeoutSec 5 -UseBasicParsing).StatusCode
    }
    catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
        return 0   # 연결 자체가 안 됐다 (앱이 안 떠 있음)
    }
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
# 이 저장소의 다른 검증 스크립트와 같은 PASS / FAIL 표기를 쓴다.
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
    param(
        [int]$ReconcileIntervalMs = 0,
        # 대사가 훑는 발급 시각 창의 상한 여유분 (cutoff = now - grace).
        [int]$GracePeriodMs = 0,
        # issued_quantity write-behind 동기화기(IssuedQuantitySynchronizer)의 주기.
        # part-5-2 에서만 크게 줘서 사실상 끈다 — 자세한 이유는 Invoke-Reconcile 주석.
        [int]$SyncIntervalMs = 0,
        # kafka 재생성을 건너뛴다. 토픽을 비울 필요가 없는 블록에서 30초를 아낀다.
        [switch]$SkipKafka
    )

    if (-not $SkipKafka) {
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
    }

    $applied = @()
    if ($ReconcileIntervalMs -gt 0) {
        $env:COUPON_RECONCILE_INTERVAL_MS = "$ReconcileIntervalMs"
        $applied += "COUPON_RECONCILE_INTERVAL_MS=$ReconcileIntervalMs"
    }
    if ($GracePeriodMs -gt 0) {
        $env:COUPON_RECONCILE_GRACE_PERIOD_MS = "$GracePeriodMs"
        $applied += "COUPON_RECONCILE_GRACE_PERIOD_MS=$GracePeriodMs"
    }
    if ($SyncIntervalMs -gt 0) {
        $env:COUPON_SYNC_INTERVAL_MS = "$SyncIntervalMs"
        $applied += "COUPON_SYNC_INTERVAL_MS=$SyncIntervalMs"
    }

    if ($applied.Count -gt 0) {
        Invoke-Step "coupon-service 재생성 ($($applied -join ', '))" {
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
    if ($GracePeriodMs -gt 0)       { Assert-EnvApplied 'COUPON_RECONCILE_GRACE_PERIOD_MS' }
    if ($SyncIntervalMs -gt 0)      { Assert-EnvApplied 'COUPON_SYNC_INTERVAL_MS' }
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
    # /admin/reconcile/run 은 POST 전용이라 GET 하면 405 다. 200 이 아니라 405 를 기대하는 것이
    # 요점 — 405 는 "핸들러는 있는데 메서드가 다르다" 는 뜻이라 라우트 존재의 증거가 된다.
    if ((Get-HttpStatus -Uri "$AppUrl/admin/reconcile/run") -eq 405) { return 'part-5-2' }

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
    # 스케줄러 둘을 사실상 꺼 둔다 (1시간).
    #
    # 대사(Reconciler): 검증 도중에 끼어들면 아래에서 읽는 값이 "수동으로 돌린 대사" 의
    #   결과인지 알 수 없게 된다.
    #
    # 발급 수 동기화(IssuedQuantitySynchronizer): 이쪽이 더 미묘하다. 이 동기화기는
    #   issued_quantity 를 Redis 재고에서 파생시킨다 (issued = total - stock).
    #   그러면 대사의 DB 측 드리프트가
    #       total - (issued + stock) = total - (total - stock) - stock = 0
    #   으로 항상 정확히 0 이 되어, ③번 블록이 원리적으로 통과할 수 없다.
    #   ③은 "DB 는 발급을 모르는데 Redis 만 줄어든" 상태를 봐야 하므로
    #   그동안 issued_quantity 가 0 으로 남아 있어야 한다.
    Restart-CouponService -ReconcileIntervalMs 3600000 -SyncIntervalMs 3600000

    # -----------------------------------------------------------------------
    # 발급이 일어나면 그 쿠폰이 "최근 대사 대상" 집합에 올라가는지
    #
    # 뒤의 두 블록은 /admin/reconcile/run 을 직접 부르지만, 실제 운용에서는
    # 스케줄러가 이 집합만 훑는다. 등록이 안 되면 자동 보정이 영원히 안 돈다 —
    # 수동 실행만 검증하면 그 구멍이 안 보인다.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "##### 최근 대사 대상 등록 #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    try {
        # 원본은 /api/coupons 를 부르지만 이 저장소의 컨트롤러 경로는 /api/v1/coupons 다.
        Invoke-RestMethod -Method Post -Uri "$AppUrl/api/v1/coupons/$couponId/issue" `
            -Headers @{ 'X-User-Id' = '800001' } | Out-Null
    }
    catch {
        Write-Host "!! 발급 요청 실패: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   경로(/api/v1/coupons/{id}/issue)와 재고를 확인하세요." -ForegroundColor DarkGray
        exit 1
    }

    # 기대값 비교가 아니라 "비어 있지 않은가" 라서 Test-Expected 대신 직접 판정한다 (원본도 같다).
    if (Invoke-RedisCli ZSCORE 'coupon:reconcile:recent' $couponId) {
        Write-Pass '발급 쿠폰을 최근 대사 대상으로 등록'
    }
    else {
        Write-Ng '발급 쿠폰을 최근 대사 대상으로 등록'
    }

    # 워커가 issuance 행을 쓸 때까지 기다린다. 안 기다리면 다음 블록의 리셋(TRUNCATE)이
    # 그 쓰기와 겹쳐서, 다음 라운드의 coupon.id=1 에 이전 라운드 행이 섞인다.
    $issuedQuery = "SELECT COUNT(*) FROM issuance WHERE coupon_id=$couponId AND user_id=800001"
    for ($i = 0; $i -lt 30; $i++) {
        if ((Invoke-MysqlScalar -Sql $issuedQuery) -eq '1') { break }
        Start-Sleep -Seconds 1
    }

    # -----------------------------------------------------------------------
    # DB 에만 있는 발급을 주입하고, 대사가 Redis 사용자 목록을 되살리는지
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "##### Redis users 누락 자동 보정 #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    & "$PSScriptRoot\force-db-only.ps1" -CouponId $couponId -Count $Count
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # 응답을 버리지 않고 받는다. 개정판의 핵심 — 방금 돌린 그 대사의 결과가 검증 대상이라
    # 누적 카운터를 따로 둘 필요가 없다 (jq -r '.autoFixed' 자리).
    $result = Invoke-RestMethod -Method Post -Uri "$AppUrl/admin/reconcile/run"

    Test-Expected -Label '발급자 명단 복구' `
        -Actual (Invoke-RedisCli SCARD "coupon:${couponId}:users") -Expected "$Count"
    Test-Expected -Label '자동 보정 횟수' -Actual "$($result.autoFixed)" -Expected '1'
    # 깨끗하게 보정됐다면 알람은 없어야 한다. 이게 0 이 아니면 보정은 됐는데 무언가
    # 안전하게 못 고친 것이 남아 있다는 뜻이다.
    Test-Expected -Label '알람 없이 보정' -Actual "$($result.driftAlerts)" -Expected '0'

    # -----------------------------------------------------------------------
    # DB 측 불일치는 자동 보정 대상이 아니다. 감지만 하고 Redis 재고는 그대로 둬야 한다
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "##### DB 측 불일치는 알람만 #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    & "$PSScriptRoot\force-dlt.ps1" -CouponId $couponId -Count $Count
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # "알람만" 이 진짜인지 보려면 대사가 건드릴 수 있었던 것들을 전부 찍어 둬야 한다.
    # 원본은 재고 하나만 보지만, early return(CouponReconciler.kt:32-34) 이 제대로 걸렸다면
    # 명단과 매진 플래그도 그대로여야 한다.
    $stockBefore   = Invoke-RedisCli GET "coupon:${couponId}:stock"
    $usersBefore   = Invoke-RedisCli SCARD "coupon:${couponId}:users"
    $soldOutBefore = Invoke-RedisCli EXISTS "coupon:${couponId}:sold_out"

    $result = Invoke-RestMethod -Method Post -Uri "$AppUrl/admin/reconcile/run"

    Test-Expected -Label 'DB 측 불일치 감지' -Actual "$($result.redisDbDrift)" -Expected "$Count"
    Test-Expected -Label '알람이 올라옴' -Actual "$($result.driftAlerts)" -Expected '1'
    Test-Expected -Label 'Redis 재고 유지' `
        -Actual (Invoke-RedisCli GET "coupon:${couponId}:stock") -Expected $stockBefore
    Test-Expected -Label 'Redis 명단 유지 (보정 안 함)' `
        -Actual (Invoke-RedisCli SCARD "coupon:${couponId}:users") -Expected $usersBefore
    Test-Expected -Label '매진 플래그 유지 (보정 안 함)' `
        -Actual (Invoke-RedisCli EXISTS "coupon:${couponId}:sold_out") -Expected $soldOutBefore

    # 원본에 없는 블록. 위 세 개는 전부 /admin/reconcile/run(= auditAll, 전체 쿠폰 findAll)이라
    # 실제 운용 경로인 scheduledRecent 를 한 번도 안 돌린다. 여기서 그걸 검증한다.
    Invoke-ScheduledReconcile
    Invoke-WatermarkRecovery

    Write-Summary 'part-5-2'
}

# ---------------------------------------------------------------------------
# 주기 대사(Reconciler.scheduledRecent)가 실제로 도는지
#
# 앞의 세 블록은 auditAll() 이라 ZSET 이 비어 있어도 통과한다. 그래서 창 계산
#     cutoff = now - grace ; from = cutoff - interval*2
# 이나 coupon:reconcile:recent 등록에 버그가 있어도 안 잡힌다.
#
# 여기서는 수동 트리거를 아예 부르지 않는다. 명단이 되살아나면 그건 스케줄러가
# ZSET 을 훑어서 한 것이다 — 대사를 부르는 곳이 그 둘뿐이기 때문이다.
# ---------------------------------------------------------------------------
function Invoke-ScheduledReconcile {
    $userId = 800001

    # 앞 블록들과 설정이 반대다.
    #  - 대사 주기: 짧게. 기다려서 봐야 하므로.
    #  - grace: 짧게. 방금 낸 발급이 창(cutoff = now - grace) 안으로 바로 들어와야 한다.
    #  - 동기화기: 켠다(1000). 여기서는 dbDrift 가 0 이어야 사용자 보정 경로까지 들어간다.
    #    꺼 두면 issued_quantity 가 0 으로 남아 dbDrift != 0 이 되고, 대사가 알람만 내고
    #    early return 해 버려서(CouponReconciler.kt:32-34) 명단을 안 고친다.
    # kafka 는 그대로 쓴다. 이 블록은 DLT 를 안 건드리므로 재생성할 이유가 없다.
    Restart-CouponService -ReconcileIntervalMs 5000 -GracePeriodMs 500 -SyncIntervalMs 1000 -SkipKafka

    Write-Host ""
    Write-Host "##### 주기 대사가 스스로 보정하는지 (수동 트리거 없음) #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    # 주입 스크립트를 쓰지 않고 진짜 발급 API 를 태운다. force-* 는 Redis/DB 를 직접 건드려서
    # coupon:reconcile:recent 에 등록되지 않고, 그러면 스케줄러가 이 쿠폰을 아예 안 본다.
    try {
        Invoke-RestMethod -Method Post -Uri "$AppUrl/api/v1/coupons/$couponId/issue" `
            -Headers @{ 'X-User-Id' = "$userId" } | Out-Null
    }
    catch {
        Write-Host "!! 발급 요청 실패: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # 워커가 issuance 행을 써야 대사가 "DB 에는 있는데 Redis 명단에 없다" 로 판단할 수 있다.
    $issuedQuery = "SELECT COUNT(*) FROM issuance WHERE coupon_id=$couponId AND user_id=$userId"
    for ($i = 0; $i -lt 30; $i++) {
        if ((Invoke-MysqlScalar -Sql $issuedQuery) -eq '1') { break }
        Start-Sleep -Seconds 1
    }
    Test-Expected -Label '발급이 DB 에 기록됨' -Actual (Invoke-MysqlScalar -Sql $issuedQuery) -Expected '1'

    # 발급 시각이 score 로 들어갔는지. 이게 없으면 스케줄러가 훑을 대상 자체가 없다.
    $score = Invoke-RedisCli ZSCORE 'coupon:reconcile:recent' $couponId
    if ($score) { Write-Pass "최근 대사 대상 ZSET 에 등록 (score=$score)" }
    else { Write-Ng '최근 대사 대상 ZSET 에 등록'; return }

    # 명단만 지운다 — 대사가 되살려야 할 바로 그 상태다.
    Invoke-RedisCli SREM "coupon:${couponId}:users" "$userId" | Out-Null
    Test-Expected -Label '명단을 일부러 날림' `
        -Actual (Invoke-RedisCli SCARD "coupon:${couponId}:users") -Expected '0'

    # 여기서부터 아무것도 부르지 않고 기다리기만 한다.
    # 창은 [cutoff - interval*2, cutoff], cutoff = now - 500 이므로 발급 시각 t0 기준
    # t0+500 ~ t0+10500 사이에 도는 실행이 이 쿠폰을 집는다. 주기가 5초라 그 안에 최소 한 번.
    Write-Host "  스케줄러 대기 중 (최대 30초, 수동 트리거 없음)..." -ForegroundColor DarkGray
    # 반복 횟수가 아니라 실제 경과 시간을 잰다. 폴링 1회에도 docker exec 왕복이 붙어서
    # 회차를 세면 실제보다 짧게 나온다.
    $started = Get-Date
    $restored = '0'
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $restored = Invoke-RedisCli SCARD "coupon:${couponId}:users"
        if ($restored -eq '1') {
            $elapsed = ((Get-Date) - $started).TotalSeconds
            Write-Host ("  {0:N1}초 만에 보정됨" -f $elapsed) -ForegroundColor DarkGray
            break
        }
    }

    Test-Expected -Label '주기 대사가 명단을 스스로 복구' -Actual $restored -Expected '1'
}

# ---------------------------------------------------------------------------
# 스케줄러가 멈춰 있는 동안 난 발급도 나중에 구제되는지 (워터마크)
#
# scheduledRecent 의 기본 창은 [cutoff - interval*2, cutoff] 라 "스케줄러가 제때 돌았다" 를
# 전제한다. 앱이 내려가 있으면 그 사이 발급은 창을 지나쳐 다시는 대사되지 않는다.
# Reconciler 는 지난 회차의 상한을 coupon:reconcile:watermark 에 남기고
#     fromMs = minOf(slidingFromMs, watermarkMs ?: slidingFromMs)
# 로 창을 넓히기만 한다. 여기서 그 구제가 실제로 도는지 본다.
#
# 앱을 진짜로 멈췄다가 다시 띄우므로 이 블록만 1분 가까이 걸린다.
# ---------------------------------------------------------------------------
function Invoke-WatermarkRecovery {
    $intervalMs = 5000
    $graceMs    = 500
    # 창 폭. 주입 시각이 이보다 오래 묵어야 "창을 놓친" 상황이 된다.
    $windowMs   = $graceMs + $intervalMs * 2

    # 동기화기는 끈다. 아래 force-db-only 가 issued_quantity 를 직접 맞춰 주므로
    # 파생값이 끼어들 이유가 없다 (dbDrift 는 0 이어야 명단 보정 경로로 들어간다).
    Restart-CouponService -ReconcileIntervalMs $intervalMs -GracePeriodMs $graceMs `
        -SyncIntervalMs 3600000 -SkipKafka

    Write-Host ""
    Write-Host "##### 스케줄러가 멈춘 사이의 발급도 구제되는지 (워터마크) #####" -ForegroundColor Magenta

    & "$PSScriptRoot\reset.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $couponId = & "$PSScriptRoot\create-coupon.ps1"
    if (-not $couponId) { Write-Host "!! 쿠폰 ID 를 받지 못했습니다." -ForegroundColor Red; exit 1 }

    # reset 이 FLUSHDB 로 워터마크까지 지웠다. 스케줄러가 한 번 돌아 새로 남기게 둔다 —
    # 이게 있어야 "멈추기 직전까지 어디를 봤는지" 가 기록된다.
    Write-Host "  워터마크가 찍히도록 한 회차 대기..." -ForegroundColor DarkGray
    Start-Sleep -Seconds ([int][math]::Ceiling($intervalMs / 1000.0) + 2)

    $watermark = Invoke-RedisCli GET 'coupon:reconcile:watermark'
    if ($watermark) { Write-Pass "워터마크 기록됨 ($watermark)" }
    else { Write-Ng '워터마크 기록됨'; return }

    # 여기서부터 스케줄러가 죽는다. mysql / redis 는 그대로 떠 있으므로 주입은 가능하다.
    Invoke-Step "coupon-service 정지 (스케줄러 중단 상황)" {
        docker compose stop coupon-service
    }

    # 앱이 없으니 발급 API 를 못 쓴다. force-db-only 가 DB/Redis 를 직접 만지고,
    # 실제 발급 경로가 하는 ZADD 만 손으로 보탠다.
    & "$PSScriptRoot\force-db-only.ps1" -CouponId $couponId -Count 1
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $injectedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-RedisCli ZADD 'coupon:reconcile:recent' "$injectedAtMs" "$couponId" | Out-Null
    Write-Host "  주입 시각 score=$injectedAtMs 로 ZSET 등록" -ForegroundColor DarkGray

    # 이 주입이 슬라이딩 창 밖으로 나가도록 묵힌다. 앱 기동 시간까지 더해지므로
    # 창 폭보다 넉넉히 벌어진다 — 그래야 "워터마크가 아니면 못 잡는" 상황이 된다.
    $ageTargetSec = [int][math]::Ceiling($windowMs / 1000.0) + 5
    Write-Host "  ${ageTargetSec}초 묵히는 중 (창 폭 ${windowMs}ms 를 넘겨야 한다)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $ageTargetSec

    Invoke-Step "coupon-service 재기동 (스케줄러 복귀)" {
        docker compose start coupon-service
    }
    if (-not (Wait-AppReady)) {
        Write-Host "!! coupon-service 가 다시 뜨지 않았습니다." -ForegroundColor Red
        exit 1
    }

    Write-Host "  스케줄러 대기 중 (최대 30초, 수동 트리거 없음)..." -ForegroundColor DarkGray
    $started  = Get-Date
    $restored = '0'
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $restored = Invoke-RedisCli SCARD "coupon:${couponId}:users"
        if ($restored -eq '1') {
            Write-Host ("  {0:N1}초 만에 보정됨" -f ((Get-Date) - $started).TotalSeconds) -ForegroundColor DarkGray
            break
        }
    }

    # 주입이 실제로 창 밖이었는지 확인한다. 안 그러면 워터마크 없이도 통과하는
    # 무의미한 검증이 된다 — 통과 자체보다 이게 더 중요하다.
    $ageMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $injectedAtMs
    if ($ageMs -gt $windowMs) {
        Write-Pass "주입이 슬라이딩 창 밖이었음 (${ageMs}ms > ${windowMs}ms)"
    }
    else {
        Write-Ng "주입이 아직 창 안이라 워터마크를 검증하지 못했다 (${ageMs}ms <= ${windowMs}ms)"
    }

    Test-Expected -Label '창을 놓친 발급을 워터마크로 구제' -Actual $restored -Expected '1'
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
