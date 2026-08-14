#Requires -Version 5.1
<#
.SYNOPSIS
    coupon / issuance 테이블과 Redis 를 비운다.

.DESCRIPTION
    응답시간 트랙(scripts/response)용. scripts/concurrency/windows/reset.ps1 과 동작이 같다.
    두 트랙이 서로 영향을 주지 않도록 일부러 복제해 두었다 — 한쪽 하네스를 고치다
    다른 쪽 측정 조건이 조용히 바뀌는 것을 막기 위해서다.

    이 트랙은 라운드를 두 번 돌리므로(워밍업 + 본 측정) 라운드 사이에 이것이 불린다.
    서비스 컨테이너는 건드리지 않는다. JVM/JIT, Hikari 풀이 살아 있어야 2회차가 steady-state 다.

.EXAMPLE
    .\scripts\response\windows\reset.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 어느 디렉터리에서 실행하든 docker-compose.yml 이 있는 프로젝트 루트 기준으로 동작하게 한다
# (scripts/response/windows -> 세 단계 위)
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
# TRUNCATE 로 coupon.id 가 1부터 다시 시작하므로, 비우지 않으면 이전 라운드가 남긴 집합을
# 그대로 물려받아 2회차부터 모든 요청이 "이미 발급" 으로 튕긴다 (발급 0건).
# 워밍업 + 본 측정으로 두 번 도는 이 트랙에서는 특히 빠지면 안 된다.
docker compose exec -T redis redis-cli FLUSHALL

if ($LASTEXITCODE -ne 0) {
    Write-Host "!! Redis 리셋 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
