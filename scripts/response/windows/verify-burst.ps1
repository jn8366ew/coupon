#Requires -Version 5.1
<#
.SYNOPSIS
    issue_burst 시나리오 검증. 쓰기가 멈출 때까지 폴링으로 기다린 뒤 결과를 낸다.

.DESCRIPTION
    scripts/response/verify_burst.sh 의 Windows 판본. 판정 기준은 bash 판과 같고,
    Redis 잔여 재고 확인만 추가했다 (아래 참고).

    concurrency 트랙의 verify.ps1 은 고정 Start-Sleep 3 초로 카운터 동기화를 기다리지만
    여기서는 issuance 행 수를 폴링해 "더 이상 늘지 않을 때" 확정한다.
    지금 구조에는 큐 워커가 없어 사실상 IssuedQuantitySynchronizer(1초 주기)를 기다리는
    것이지만, 쓰기를 비동기로 빼는 구현으로 넘어가면 그때 필요한 것이 이 폴링이다.

.EXAMPLE
    .\scripts\response\windows\verify-burst.ps1 -CouponId 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$CouponId,
    [int]$TimeoutSeconds = 60,
    [int]$StableSeconds = 3
)

$ErrorActionPreference = 'Stop'

# scripts/response/windows -> 저장소 루트
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

function Get-IssuanceRowCount {
    $raw = docker compose exec -T -e MYSQL_PWD=coupon mysql `
        mysql -ucoupon -BN coupon -e "SELECT COUNT(*) FROM issuance WHERE coupon_id = $CouponId"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! 조회 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }

    $line = ($raw | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    return [long]($line.Trim())
}

# ---------------------------------------------------------------------------
# 1) 쓰기 드레인 대기
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===== 쓰기 드레인 대기 (최대 ${TimeoutSeconds}s, ${StableSeconds}s 안정 시 확정) =====" -ForegroundColor Cyan

$prev = Get-IssuanceRowCount
$stable = 0
$elapsed = 0

while ($elapsed -lt $TimeoutSeconds) {
    Start-Sleep -Seconds 1
    $elapsed++

    $current = Get-IssuanceRowCount

    if ($current -eq $prev) {
        $stable++
        if ($stable -ge $StableSeconds) { break }
    }
    else {
        $stable = 0
        Write-Host "  +${elapsed}s issuance rows: $current"
    }

    $prev = $current
}

if ($elapsed -ge $TimeoutSeconds) {
    Write-Host "  주의: ${TimeoutSeconds}s 안에 안정되지 않았습니다. 아직 쓰기가 진행 중일 수 있습니다." -ForegroundColor Yellow
}
Write-Host "  드레인 완료. issuance rows = $prev"

# ---------------------------------------------------------------------------
# 2) 판정
# ---------------------------------------------------------------------------
$sql = @"
  SELECT
    (SELECT issued_quantity FROM coupon   WHERE id        = $CouponId) AS issued_quantity,
    (SELECT total_quantity  FROM coupon   WHERE id        = $CouponId) AS total_quantity,
    (SELECT COUNT(*)        FROM issuance WHERE coupon_id = $CouponId) AS issuance_rows,
    IF((SELECT COUNT(*) FROM issuance WHERE coupon_id = $CouponId)
        > (SELECT total_quantity FROM coupon WHERE id = $CouponId), 'FAIL', 'OK') AS over_issuance,
    IF((SELECT issued_quantity FROM coupon WHERE id = $CouponId)
        = (SELECT COUNT(*) FROM issuance WHERE coupon_id = $CouponId), 'OK', 'FAIL') AS count_match;
"@

Write-Host ""

# 사람이 볼 표
docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -t coupon -e $sql
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 조회 실패 (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

# 같은 SQL 을 batch 모드(-BN: 헤더 없이 탭 구분)로 다시 받아 판정
$raw = docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e $sql
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 조회 실패 (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

$line = ($raw | Where-Object { $_ -match '\S' } | Select-Object -First 1)
$cols = $line -split "`t"

if ($cols.Count -lt 5) {
    Write-Host "!! 결과를 해석할 수 없습니다: $line" -ForegroundColor Red
    Write-Host "   COUPON_ID=$CouponId 인 쿠폰이 있는지 확인하세요." -ForegroundColor DarkGray
    exit 1
}

$issuedQuantity = [long]$cols[0]
$totalQuantity  = [long]$cols[1]
$issuanceRows   = [long]$cols[2]
$overIssuance   = $cols[3]
$countMatch     = $cols[4]

Write-Host ""
if ($overIssuance -eq 'FAIL') {
    Write-Host "FAIL: 과발급 (실제발급 $issuanceRows > 재고 $totalQuantity)" -ForegroundColor Red
}
elseif ($countMatch -eq 'FAIL') {
    # bash 원본과 같은 semantics 로 WARN 에 둔다. issued_quantity 는 Redis 재고에서 파생돼
    # 주기적으로 따라오는 값이라, 드레인이 끝나도 한 박자 늦을 수 있다.
    Write-Host "WARN: 카운터 불일치 (issued_quantity $issuedQuantity, 실제발급 $issuanceRows)" -ForegroundColor Yellow
    Write-Host "  -> 파생 카운터가 아직 안 따라왔거나, 쓰기 경로가 카운터를 갱신하지 않는다는 뜻." -ForegroundColor DarkGray
}
else {
    Write-Host "PASS: issuance_rows $issuanceRows, issued_quantity $issuedQuantity, total $totalQuantity" -ForegroundColor Green

    # 발급이 0건이면 결함이 없는 게 아니라 부하가 안 걸린 것이다. PASS 로 오독하기 쉬워 경고한다.
    if ($issuanceRows -eq 0) {
        Write-Host "  주의: 발급이 0건입니다. 요청이 앱에 닿지 않았을 수 있습니다." -ForegroundColor Yellow
        Write-Host "        k6 요약의 checks 와 status_conn_error 를 확인하세요." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 3) Redis 잔여 재고 — DB 만 보는 검증이 놓치는 것
#
# 위 세 판정은 전부 DB 안에서만 계산되므로 Redis 와 DB 사이에서 새는 과소발급을 잡지 못한다.
# 실제로 lua 태그에서 재고 23장이 아무에게도 가지 않고 사라졌는데 OK/OK/PASS 가 나온 적이 있다
# (docs/load-test-k6.md 12.2). 그래서 이 트랙은 처음부터 같이 본다.
#
# 읽는 시점이 중요하다: k6 직후, 다음 라운드의 reset(FLUSHALL) 이전이어야 한다.
# ---------------------------------------------------------------------------
Write-Host ""

# "coupon:$CouponId:stock" 로 쓰면 PowerShell 이 $CouponId:stock 을 드라이브 한정 변수로
# 파싱해 빈 값이 된다. 반드시 ${} 로 감싼다.
$stockKey = "coupon:${CouponId}:stock"
$stockRaw = docker compose exec -T redis redis-cli GET $stockKey

if ($LASTEXITCODE -ne 0) {
    Write-Host "주의: Redis 재고를 읽지 못했습니다 (exit code $LASTEXITCODE)." -ForegroundColor Yellow
    return
}

$stockLine = ($stockRaw | Where-Object { $_ -match '\S' } | Select-Object -First 1)

if (-not $stockLine -or $stockLine.Trim() -eq '') {
    Write-Host "주의: Redis 에 $stockKey 가 없습니다. 쿠폰 생성 시 initStock 이 돌았는지 확인하세요." -ForegroundColor Yellow
    return
}

$remainingStock = [long]($stockLine.Trim())
$expectedStock = $totalQuantity - $issuanceRows

if ($remainingStock -eq $expectedStock) {
    Write-Host "Redis 재고 OK: $stockKey = $remainingStock (= $totalQuantity - $issuanceRows)" -ForegroundColor Green
}
else {
    $leak = $expectedStock - $remainingStock
    Write-Host "WARN: Redis 재고 누수 $leak 장 ($stockKey = $remainingStock, 기대값 $expectedStock)" -ForegroundColor Yellow
    Write-Host "  -> Redis 를 차감한 뒤 DB 쓰기가 실패했는데 재고를 되돌리지 않았다는 뜻이다." -ForegroundColor DarkGray
    Write-Host "     DB 안에서는 아무 모순이 없어 위 판정은 PASS 로 나온다 (docs/load-test-k6.md 12.2)." -ForegroundColor DarkGray
}
