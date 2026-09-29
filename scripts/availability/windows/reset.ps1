#Requires -Version 5.1
<#
.SYNOPSIS
    coupon / issuance 테이블과 Redis 를 비운다.

.DESCRIPTION
    가용성 트랙(scripts/availability)용. scripts/response/windows/reset.ps1 과 동작이 같다.
    트랙끼리 공유하지 않고 일부러 복제해 두었다 — 한쪽 하네스를 고치다
    다른 쪽 측정 조건이 조용히 바뀌는 것을 막기 위해서다.

    이 트랙에서 Redis FLUSHALL 은 특히 빠지면 안 된다. 대기실은 상태를 전부 Redis 에 두므로
    (waiting:{id}:queue 정렬집합, waiting:{id}:pass<userId> 입장권), 안 비우면 이전 실행이
    남긴 줄과 입장권을 그대로 물려받는다 — 순번 검증이 어긋나고 입장권 개수 판정도 부풀려진다.

.EXAMPLE
    .\scripts\availability\windows\reset.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 어느 디렉터리에서 실행하든 docker-compose.yml 이 있는 프로젝트 루트 기준으로 동작하게 한다
# (scripts/availability/windows -> 세 단계 위)
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

# Redis 도 같이 비운다 (위 .DESCRIPTION 참고).
docker compose exec -T redis redis-cli FLUSHALL

if ($LASTEXITCODE -ne 0) {
    Write-Host "!! Redis 리셋 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
