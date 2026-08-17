#Requires -Version 5.1
<#
.SYNOPSIS
    coupon / issuance 테이블과 Redis 를 비운다.

.DESCRIPTION
    정합성 트랙(scripts/consistency)용. 다른 트랙의 reset.ps1 과 동작이 같다.
    트랙끼리 공유하지 않고 일부러 복제해 두었다 — 한쪽 하네스를 고치다
    다른 쪽 조건이 조용히 바뀌는 것을 막기 위해서다.

    강의 원본(run.sh)은 ./scripts/load/reset.sh 를 부르지만 이 저장소에는 그 경로가 없다.
    트랙 재편 전 레이아웃이라 그대로 두면 "파일 없음" 으로 죽는다.

    Redis 를 같이 비우는 것이 중요하다. TRUNCATE 로 coupon.id 가 1 부터 다시 시작하므로,
    안 비우면 이전 실행이 남긴 coupon:1:users / coupon:1:stock 을 그대로 물려받는다.
    이 트랙은 "DB 와 Redis 가 얼마나 어긋났는가" 를 세는 것이라 그 잔재가 곧 가짜 불일치가 된다.

    Kafka 토픽은 비우지 않는다. 이 트랙은 일부러 DLT 에 메시지를 넣으므로
    지우면 주입한 것까지 사라진다 (run.ps1 의 Restart-CouponService 는 kafka 를
    --force-recreate 하는데, 볼륨이 없어 그때는 토픽이 통째로 사라진다).

.EXAMPLE
    .\scripts\consistency\windows\reset.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 어느 디렉터리에서 실행하든 docker-compose.yml 이 있는 프로젝트 루트 기준으로 동작하게 한다
# (scripts/consistency/windows -> 세 단계 위)
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

docker compose exec -T redis redis-cli FLUSHALL

if ($LASTEXITCODE -ne 0) {
    Write-Host "!! Redis 리셋 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
