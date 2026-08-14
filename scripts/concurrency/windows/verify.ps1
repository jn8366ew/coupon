#Requires -Version 5.1
<#
.SYNOPSIS
    발급량과 동시성 결함을 확인한다.

.DESCRIPTION
    scripts/concurrency/load/verify.sh 의 Windows 판본. 판정 기준은 bash 판과 동일하다.

    issued_quantity  coupon.issued_quantity (카운터 필드)
    total_quantity   재고 총량
    issuance_rows    실제 발급된 issuance 행 수
    duplicate_users  같은 user 가 같은 coupon 을 2번 이상 받은 수 (UNIQUE 있으면 항상 0)
    over_issuance    issuance_rows > total_quantity  → 전역 N장 깨짐
    count_match      issued_quantity = issuance_rows → 카운터가 실제와 맞음 (race 없음)

.EXAMPLE
    .\scripts\concurrency\windows\verify.ps1 -CouponId 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$CouponId
)

$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

$sql = @"
  SELECT
    v.issued_quantity, v.total_quantity, v.issuance_rows, v.duplicate_users,
    IF(v.issuance_rows > v.total_quantity, 'FAIL', 'OK') AS over_issuance,
    IF(v.issued_quantity = v.issuance_rows, 'OK', 'FAIL') AS count_match
  FROM (
    SELECT
      (SELECT issued_quantity FROM coupon   WHERE id        = $CouponId) AS issued_quantity,
      (SELECT total_quantity  FROM coupon   WHERE id        = $CouponId) AS total_quantity,
      (SELECT COUNT(*)        FROM issuance WHERE coupon_id = $CouponId) AS issuance_rows,
      (SELECT COUNT(*) FROM (SELECT user_id FROM issuance WHERE coupon_id = $CouponId
        GROUP BY user_id HAVING COUNT(*) > 1) t)                         AS duplicate_users
  ) v;
"@

# 1) 사람이 볼 표 출력
docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -t coupon -e $sql
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 조회 실패 (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

# 2) 같은 SQL 을 batch 모드(-BN: 헤더 없이 탭 구분)로 다시 받아 판정
$raw = docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e $sql
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 조회 실패 (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

# 여러 줄로 올 수 있으니 내용이 있는 첫 줄만 쓴다
$line = ($raw | Where-Object { $_ -match '\S' } | Select-Object -First 1)
$cols = $line -split "`t"

if ($cols.Count -lt 6) {
    Write-Host "!! 결과를 해석할 수 없습니다: $line" -ForegroundColor Red
    Write-Host "   COUPON_ID=$CouponId 인 쿠폰이 있는지 확인하세요." -ForegroundColor DarkGray
    exit 1
}

$issuedQuantity = $cols[0]
$totalQuantity  = $cols[1]
$issuanceRows   = $cols[2]
$overIssuance   = $cols[4]
$countMatch     = $cols[5]

Write-Host ""
if ($overIssuance -eq 'FAIL') {
    Write-Host "FAIL: 과발급 (실제발급 $issuanceRows > 재고 $totalQuantity)" -ForegroundColor Red
}
elseif ($countMatch -eq 'FAIL') {
    Write-Host "FAIL: 카운터 불일치 (issued_quantity $issuedQuantity, 실제발급 $issuanceRows)" -ForegroundColor Red
}
else {
    Write-Host "PASS" -ForegroundColor Green

    # 발급이 0건이면 결함이 없는 게 아니라 부하가 안 걸린 것이다. PASS 로 오독하기 쉬워 경고한다.
    if ($issuanceRows -eq '0') {
        Write-Host "  주의: 발급이 0건입니다. 결함이 없는 게 아니라 요청이 앱에 닿지 않았을 수 있습니다." -ForegroundColor Yellow
        Write-Host "        k6 요약의 checks 항목과 http_req_failed 를 확인하세요." -ForegroundColor DarkGray
    }
}
