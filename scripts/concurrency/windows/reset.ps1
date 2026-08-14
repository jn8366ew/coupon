#Requires -Version 5.1
<#
.SYNOPSIS
    coupon / issuance 테이블을 비운다.

.DESCRIPTION
    부하 테스트는 매번 깨끗한 상태에서 시작해야 발급 수를 재고와 비교할 수 있다.
    mysql 컨테이너 안에서 TRUNCATE 후 행 수를 확인한다 (둘 다 0 이어야 정상).

    scripts/concurrency/load/reset.sh 의 Windows 판본.

.EXAMPLE
    .\scripts\concurrency\windows\reset.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 어느 디렉터리에서 실행하든 docker-compose.yml 이 있는 프로젝트 루트 기준으로 동작하게 한다
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

$sql = @'
SET FOREIGN_KEY_CHECKS=0; TRUNCATE issuance; TRUNCATE coupon; SET FOREIGN_KEY_CHECKS=1;
SELECT (SELECT COUNT(*) FROM coupon)   AS coupon_rows,
       (SELECT COUNT(*) FROM issuance) AS issuance_rows;
'@

Write-Host ""
Write-Host "===== coupon, issuance 데이터 리셋 =====" -ForegroundColor Cyan

docker compose exec -T -e MYSQL_PWD=coupon mysql mysql -ucoupon -t coupon -e $sql

# docker 같은 네이티브 exe 는 $ErrorActionPreference 를 따르지 않는다. 종료 코드를 직접 본다.
if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 리셋 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
    exit $LASTEXITCODE
}

# Redis 도 같이 비운다.
#
# 발급 자격 판정이 Redis 로 옮겨오면서 coupon:{id}:issued 집합에 사용자가 누적된다.
# TRUNCATE 로 coupon.id 가 1부터 다시 시작하므로, 비우지 않으면 이전 실행이 남긴 집합을
# 그대로 물려받아 두 번째 실행부터 모든 요청이 "이미 발급" 으로 튕긴다 (발급 0건).
# 재고 키는 쿠폰 생성 때 initStock 이 덮어쓰므로 지금까지는 이 문제가 드러나지 않았다.
docker compose exec -T redis redis-cli FLUSHALL

if ($LASTEXITCODE -ne 0) {
    Write-Host "!! Redis 리셋 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
