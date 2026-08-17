#Requires -Version 5.1
<#
.SYNOPSIS
    [상황 만들기] 사용자에겐 발급 성공인데 DB 저장이 끝내 실패한 상태를 만든다.

.DESCRIPTION
    scripts/consistency/force_dlt.sh 의 Windows 판본. 주입하는 내용은 원본과 같다.

        Redis : 재고 $Count 줄이고 발급자 명단(coupon:{id}:users)에 $Count 명 추가
        Kafka : 그 $Count 건을 DLT(실패 메시지 보관함) 토픽에 직접 넣는다
        DB    : 아무것도 넣지 않는다  ← 여기가 어긋난 부분

    DLT 재처리(part-5-1)가 되살려야 하는 쪽이다.

    ! 원본이 만드는 JSON 의 키는 issuedAt 인데 이 저장소의 IssuanceRequested 필드명은
      issueAt 이다. part-5-0 에서는 이 메시지를 아무도 읽지 않아 문제가 없지만,
      part-5-1 에서 replay 를 붙이면 역직렬화가 여기서 먼저 깨진다.
      원본과 맞춰 두었으니 그 단계에 가서 둘 중 하나를 맞출 것.

    Kafka 프로듀서에 PowerShell 파이프라인으로 문자열을 직접 넣지 않는다.
    파이프라인은 줄바꿈을 CRLF 로 내보내므로 메시지 값 끝에 \r 이 붙어 버린다 —
    화면상 멀쩡해 보이고 나중에 JSON 파싱이 조용히 깨지는 자리다.
    그래서 페이로드를 base64 로 감싸 컨테이너 안에서 풀어 파이프한다
    (apache/kafka:3.8.0 은 Alpine 이라 /bin/base64 가 있다).

.EXAMPLE
    .\scripts\consistency\windows\force-dlt.ps1 -CouponId 1
    기본 10건.

.EXAMPLE
    .\scripts\consistency\windows\force-dlt.ps1 -CouponId 1 -Count 1 -UserBase 900000
    part-5-1 replay 검증용. 사용자 900001 한 명만.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$CouponId,
    [int]$Count = 10,
    # force-db-only.ps1 의 800000 과 겹치지 않게 나눠 둔 구간이다.
    [long]$UserBase = 900000,
    [string]$Topic = 'issuance.requested.DLT'
)

$ErrorActionPreference = 'Stop'

# docker compose 를 쓰므로 프로젝트 루트에서 돌아야 한다 (scripts/consistency/windows -> 세 단계 위)
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

function Invoke-RedisCli {
    $out = (docker compose exec -T redis redis-cli @args | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! redis-cli 실패 (exit code $LASTEXITCODE). 컨테이너가 떠 있는지 확인하세요." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    return $out
}

# 원본의 date -u / date -u -v+7d. -v 는 BSD(mac) 전용이라 Windows 에서는 그대로 안 돈다.
$nowUtc    = (Get-Date).ToUniversalTime()
$issuedAt  = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ss')
$expiresAt = $nowUtc.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ss')

Write-Host ""
Write-Host "===== [상황 만들기] 발급은 됐는데 DB 저장이 실패한 경우 $Count 건 (force_dlt) =====" -ForegroundColor Cyan

$userIds = @(1..$Count | ForEach-Object { $UserBase + $_ })

# "coupon:$CouponId:users" 로 쓰면 PowerShell 이 $CouponId:users 를 드라이브 한정 변수로
# 파싱해 빈 값이 된다. 반드시 ${} 로 감싼다.
$usersKey = "coupon:${CouponId}:users"
$stockKey = "coupon:${CouponId}:stock"

if ((Invoke-RedisCli SISMEMBER $usersKey $userIds[0]) -eq '1') {
    Write-Host "  이미 주입된 쿠폰입니다. 먼저 .\scripts\consistency\windows\reset.ps1 로 초기화한 뒤 다시 실행하세요." -ForegroundColor Yellow
    exit 1
}

Invoke-RedisCli DECRBY $stockKey $Count | Out-Null
Invoke-RedisCli SADD $usersKey @userIds | Out-Null

Write-Host ("  Redis: 재고 {0} 줄이고 발급자 명단에 {0}명 추가 ({1}~{2} 번)  <- 사용자에겐 발급 성공으로 보임" `
        -f $Count, $userIds[0], $userIds[-1])

# 한 줄에 메시지 하나. 마지막 줄에도 개행이 있어야 kafka-console-producer 가 그 줄을 흘려보낸다.
$payload = (($userIds | ForEach-Object {
            '{{"couponId":{0},"userId":{1},"issuedAt":"{2}","expiresAt":"{3}"}}' -f $CouponId, $_, $issuedAt, $expiresAt
        }) -join "`n") + "`n"

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))

# base64 는 [A-Za-z0-9+/=] 뿐이라 sh 작은따옴표 안에서 이스케이프 걱정이 없다.
docker compose exec -T kafka sh -c `
    "echo '$b64' | base64 -d | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic $Topic" | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "!! DLT 토픽 투입 실패 (exit code $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "   kafka 컨테이너가 healthy 인지 확인하세요 (docker compose ps kafka)." -ForegroundColor DarkGray
    exit $LASTEXITCODE
}

Write-Host "  Kafka: DB 저장이 끝내 실패한 메시지 $Count 건을 DLT(실패 메시지 보관함)에 넣음"
Write-Host "  완료: DB 에는 발급 기록이 없고 Redis 만 발급된 상태 -> DB 쪽 숫자가 어긋납니다." -ForegroundColor Green
