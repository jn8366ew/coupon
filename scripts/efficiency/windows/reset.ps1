#Requires -Version 5.1
<#
.SYNOPSIS
    coupon / issuance 테이블과 Redis 를 비운다.

.DESCRIPTION
    효율 트랙(scripts/efficiency)용. scripts/response/windows/reset.ps1 과 동작이 같다.
    트랙끼리 공유하지 않고 일부러 복제해 두었다 — 한쪽 하네스를 고치다
    다른 쪽 측정 조건이 조용히 바뀌는 것을 막기 위해서다.

    이 트랙도 라운드를 두 번 돌리므로(워밍업 + 본 측정) 라운드 사이에 이것이 불린다.
    서비스 컨테이너는 건드리지 않는다. JVM/JIT, Hikari 풀이 살아 있어야 2회차가 steady-state 다.

.EXAMPLE
    .\scripts\efficiency\windows\reset.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 어느 디렉터리에서 실행하든 docker-compose.yml 이 있는 프로젝트 루트 기준으로 동작하게 한다
# (scripts/efficiency/windows -> 세 단계 위)
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
# 재고 카운터(coupon:{id}:stock)와 발급자 집합(coupon:{id}:users)이 여기 남는다.
# TRUNCATE 로 coupon.id 가 1부터 다시 시작하므로, 비우지 않으면 이전 라운드가 남긴 상태를
# 그대로 물려받는다 — 특히 시나리오 ②는 "매진시킨 뒤에 폭주" 가 전제라 이전 라운드의
# 매진 상태를 물려받으면 sell-out 이 무의미해진다.
docker compose exec -T redis redis-cli FLUSHALL

if ($LASTEXITCODE -ne 0) {
    Write-Host "!! Redis 리셋 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
