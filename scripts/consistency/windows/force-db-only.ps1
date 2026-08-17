#Requires -Version 5.1
<#
.SYNOPSIS
    [상황 만들기] DB 엔 발급 기록이 있는데 Redis 발급자 명단에는 없는 상태를 만든다.

.DESCRIPTION
    scripts/consistency/force_db_only.sh 의 Windows 판본. 주입하는 내용은 원본과 같다.

        DB    : issuance 에 $Count 건 INSERT + coupon.issued_quantity 를 $Count 증가
        Redis : 재고만 $Count 줄이고 발급자 명단(coupon:{id}:users)에는 넣지 않는다

    "명단이 날아간" 상황이라, 대사(reconcile)가 자동 보정해야 하는 쪽이다.

.EXAMPLE
    .\scripts\consistency\windows\force-db-only.ps1 -CouponId 1
    기본 10건.

.EXAMPLE
    .\scripts\consistency\windows\force-db-only.ps1 -CouponId 1 -Count 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$CouponId,
    [int]$Count = 10,
    # force-dlt.ps1 의 900000 과 겹치지 않게 나눠 둔 구간이다. 같은 쿠폰에 둘 다 주입할 때
    # 어느 쪽이 만든 행인지 user_id 만 보고 구분할 수 있다.
    [long]$UserBase = 800000
)

$ErrorActionPreference = 'Stop'

# docker compose 를 쓰므로 프로젝트 루트에서 돌아야 한다 (scripts/consistency/windows -> 세 단계 위)
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

function Invoke-MysqlExec {
    param([Parameter(Mandatory)][string]$Sql)

    $out = docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -BN coupon -e $Sql
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! MySQL 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    return ($out | Where-Object { $_ -match '\S' } | Select-Object -First 1)
}

Write-Host ""
Write-Host "===== [상황 만들기] DB 엔 발급됐는데 Redis 명단이 날아간 경우 $Count 건 (force_db_only) =====" -ForegroundColor Cyan

$first = $UserBase + 1
$last  = $UserBase + $Count

$values = (1..$Count | ForEach-Object {
        $uid = $UserBase + $_
        "($uid, $CouponId, 'ISSUED', NOW(), DATE_ADD(NOW(), INTERVAL 7 DAY))"
    }) -join ','

$existing = Invoke-MysqlExec -Sql `
    "SELECT COUNT(*) FROM issuance WHERE coupon_id = $CouponId AND user_id BETWEEN $first AND $last"

if ($existing -ne '0') {
    Write-Host "  이미 주입된 쿠폰입니다. 먼저 .\scripts\consistency\windows\reset.ps1 로 초기화한 뒤 다시 실행하세요." -ForegroundColor Yellow
    exit 1
}

$insert = @"
INSERT INTO issuance (user_id, coupon_id, status, issued_at, expires_at) VALUES $values;
UPDATE coupon SET issued_quantity = issued_quantity + $Count WHERE id = $CouponId;
"@

Invoke-MysqlExec -Sql $insert | Out-Null
Write-Host "  DB: 발급 기록 $Count 건 추가 + 발급 수 $Count 증가 ($first~$last 번)"

# "coupon:$CouponId:stock" 로 쓰면 PowerShell 이 $CouponId:stock 을 드라이브 한정 변수로
# 파싱해 빈 값이 된다. 반드시 ${} 로 감싼다.
docker compose exec -T redis redis-cli DECRBY "coupon:${CouponId}:stock" $Count | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! Redis DECRBY 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "  Redis: 재고만 $Count 줄이고 발급자 명단에는 안 넣음 (명단이 날아간 상황 재현)"
Write-Host "  완료: DB 엔 기록이 있는데 Redis 명단엔 없음 -> 명단 쪽 숫자가 어긋납니다." -ForegroundColor Green

# 참고: IssuedQuantitySynchronizer 가 살아나면(CouponApplication 에 @EnableScheduling 이 붙으면)
# issued_quantity 는 1초마다 (총 수량 - Redis 재고) 로 덮인다. 이 시나리오에서는 우연히 같은
# 값이라 티가 안 나지만, force-dlt 쪽은 그때 drift 리포트의 "DB 불일치" 가 0 으로 가려진다.
