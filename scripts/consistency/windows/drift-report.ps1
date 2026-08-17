#Requires -Version 5.1
<#
.SYNOPSIS
    쿠폰 하나에 대해 DB 와 Redis 가 얼마나 어긋났는지 출력한다.

.DESCRIPTION
    scripts/consistency/drift_report.sh 의 Windows 판본. 계산식과 판정 4갈래는 원본과 같다.

        DB 불일치     = 총 수량 - coupon.issued_quantity - Redis 잔여 재고
        사용자 불일치 = 총 수량 - Redis 사용자 수        - Redis 잔여 재고

    ! "DB 불일치" 는 IssuedQuantitySynchronizer 가 도는 순간 의미를 잃는다.
      그 스케줄러는 coupon.issued_quantity 를 (총 수량 - Redis 잔여 재고) 로 덮어쓰므로
      켜져 있으면 위 첫 식이 항상 0 으로 떨어진다 — force-dlt 로 10건을 넣어도 "=> 정상" 이 된다.

      지금은 CouponApplication 에 @EnableScheduling 이 붙어 있지 않아 스케줄러가 아예 안 돈다.
      그래서 강의 원본 계산이 그대로 성립한다 (force-dlt 뒤 DB 불일치 10).
      나중에 @EnableScheduling 이 붙으면 이 칸이 조용히 0 으로 바뀌므로,
      아래에 (ISSUED n) 행 수 기준 교차 확인을 한 줄 붙여 두었다.
      자세한 내용은 scripts/consistency/windows/README.md.

.EXAMPLE
    .\scripts\consistency\windows\drift-report.ps1 -CouponId 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$CouponId
)

$ErrorActionPreference = 'Stop'

# docker compose 를 쓰므로 프로젝트 루트에서 돌아야 한다 (scripts/consistency/windows -> 세 단계 위)
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# redis-cli 출력에는 개행/공백이 섞여 오므로 잘라낸다.
function Invoke-RedisCli {
    $out = (docker compose exec -T redis redis-cli @args | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! redis-cli 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    return $out
}

# 원본의 mysql_scalar 세 번 대신 한 번에 세 값을 받는다 (docker exec 왕복이 그만큼 준다).
$sql = @"
SELECT c.total_quantity,
       c.issued_quantity,
       (SELECT COUNT(*) FROM issuance i WHERE i.coupon_id = c.id AND i.status = 'ISSUED')
FROM coupon c WHERE c.id = $CouponId;
"@

$raw = docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e $sql
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 조회 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
    exit $LASTEXITCODE
}

$line = ($raw | Where-Object { $_ -match '\S' } | Select-Object -First 1)
$cols = if ($line) { $line -split "`t" } else { @() }

if ($cols.Count -lt 3) {
    Write-Host "!! 쿠폰 $CouponId 가 없습니다." -ForegroundColor Red
    exit 1
}

$total      = [long]$cols[0].Trim()
$issued     = [long]$cols[1].Trim()
$issuedRows = [long]$cols[2].Trim()

# "coupon:$CouponId:stock" 로 쓰면 PowerShell 이 $CouponId:stock 을 드라이브 한정 변수로
# 파싱해 빈 값이 된다. 반드시 ${} 로 감싼다.
$stockRaw = Invoke-RedisCli GET "coupon:${CouponId}:stock"
$stock    = if ($stockRaw) { [long]$stockRaw } else { 0 }   # 원본의 ${stock:-0}
$users    = [long](Invoke-RedisCli SCARD "coupon:${CouponId}:users")
$soldOut  = Invoke-RedisCli EXISTS "coupon:${CouponId}:sold_out"

$dbGap   = $total - $issued - $stock
$listGap = $total - $users - $stock

Write-Host ""
Write-Host "===== 쿠폰 $CouponId 상태 =====" -ForegroundColor Cyan
Write-Host ("  총 수량          : {0}" -f $total)
Write-Host ("  DB 발급 수       : {0} (ISSUED {1})" -f $issued, $issuedRows)
Write-Host ("  Redis 잔여 재고  : {0}" -f $stock)
Write-Host ("  Redis 사용자 수  : {0}" -f $users)
Write-Host ("  매진 표시        : {0}" -f $soldOut)
Write-Host ("  DB 불일치        : {0}" -f $dbGap)
Write-Host ("  사용자 불일치    : {0}" -f $listGap)

if ($dbGap -eq 0 -and $listGap -eq 0) {
    Write-Host "  => 정상" -ForegroundColor Green
}
elseif ($dbGap -gt 0 -and $listGap -eq 0) {
    Write-Host "  => DB 저장 실패: DLT 재처리 대상" -ForegroundColor Yellow
}
elseif ($dbGap -eq 0 -and $listGap -gt 0) {
    Write-Host "  => Redis users 누락: 대사 자동 보정 대상" -ForegroundColor Yellow
}
else {
    Write-Host "  => 자동 보정하지 않고 확인이 필요한 상태" -ForegroundColor Red
}

# 위 판정은 issued_quantity(파생 가능한 열)를 쓴다. IssuedQuantitySynchronizer 가 켜지면
# 그 열이 (총 수량 - 재고) 로 덮여 DB 불일치가 0 으로 보이게 된다 — 결함이 사라진 게 아니라
# 가려진 것이다. 실제 issuance 행 수로 다시 재서, 가려졌을 때만 한 줄 더 찍는다.
$missingRows = ($total - $stock) - $issuedRows
if ($dbGap -eq 0 -and $missingRows -gt 0) {
    Write-Host ("  => 주의: DB 행 기준으로는 {0}건이 비어 있다 (재고는 {1}만큼 깎였는데 ISSUED 는 {2})" `
            -f $missingRows, ($total - $stock), $issuedRows) -ForegroundColor Yellow
    Write-Host "     issued_quantity 가 재고에서 파생돼 위 'DB 불일치' 를 0 으로 가리고 있습니다." -ForegroundColor DarkGray
}
