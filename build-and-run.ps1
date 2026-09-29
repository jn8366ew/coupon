#Requires -Version 5.1
<#
.SYNOPSIS
    이미지 tar 빌드 -> Docker 로드 -> compose 기동.

.DESCRIPTION
    jibDockerBuild 는 Jib 3.4.4 의 `docker info` 교착 때문에 무한정 멈추므로
    Docker CLI 를 타지 않는 jibBuildTar + docker load 조합을 쓴다.
    자세한 내용은 docs/jib-docker-build-troubleshooting.md 참고.

.EXAMPLE
    .\build-and-run.ps1
    빌드하고 컨테이너를 띄운 뒤 상태를 출력한다. (태그: latest)

.EXAMPLE
    .\build-and-run.ps1 -Tag pessimistic
    coupon-service:pessimistic 으로 빌드해서 띄운다.
    구현을 바꿔 가며 비교할 때 쓴다. 다른 태그의 이미지는 그대로 남는다.
    선택한 태그는 .env 에 기록되어 이후 docker compose 명령에 그대로 적용된다.

.EXAMPLE
    .\build-and-run.ps1 -Tag naive -NoBuild
    빌드하지 않고 이미 만들어 둔 coupon-service:naive 이미지로 전환만 한다.

    이전 구현으로 되돌아가 다시 측정할 때 반드시 이 옵션을 쓴다.
    -NoBuild 없이 실행하면 "현재 소스" 를 빌드해 naive 라는 이름표를 붙이므로,
    알맹이는 최신 코드인데 이름만 예전인 이미지가 만들어지고 진짜 예전 이미지는 사라진다.

.EXAMPLE
    .\build-and-run.ps1 -Logs
    기동까지 마친 뒤 앱 로그를 계속 따라간다. (Ctrl+C 로 빠져나와도 컨테이너는 계속 뜬 상태)

.EXAMPLE
    .\build-and-run.ps1 -StopDaemon
    Gradle 데몬이 꼬였다고 판단될 때만. 재기동에 10초쯤 더 든다.
#>
[CmdletBinding()]
param(
    [string]$Tag = 'latest',
    [switch]$NoBuild,
    [switch]$Logs,
    [switch]$StopDaemon
)

# 어느 디렉터리에서 실행하든 프로젝트 루트 기준으로 동작하게 한다
Set-Location -LiteralPath $PSScriptRoot

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan

    & $Body

    # gradlew.bat / docker 같은 네이티브 exe 는 $ErrorActionPreference 를 따르지 않는다.
    # 종료 코드를 직접 봐야 한다.
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "!! 실패: $Name (exit code $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

if ($StopDaemon -and -not $NoBuild) {
    Invoke-Step "Gradle 데몬 정지" { .\gradlew.bat --stop }
}

if ($NoBuild) {
    # 이전 구현으로 되돌아갈 때 쓰는 경로. 빌드하지 않으므로 이미지의 알맹이가
    # 그대로 보존된다. 대신 "쓰려는 이미지가 진짜 있는지" 를 확인해야 한다.
    Write-Host ""
    Write-Host "==> 빌드 건너뜀 (-NoBuild) — 기존 이미지 사용" -ForegroundColor Cyan

    docker image inspect "coupon-service:$Tag" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! coupon-service:$Tag 이미지가 없습니다." -ForegroundColor Red
        Write-Host "   있는 이미지: " -ForegroundColor DarkGray
        docker images coupon-service --format "     {{.Repository}}:{{.Tag}}"
        Write-Host "   새로 빌드하려면 -NoBuild 를 빼고 실행하세요." -ForegroundColor DarkGray
        exit 1
    }

    # 생성 시각을 같이 보여준다. 예전 구현을 쓰려는데 "몇 분 전" 으로 나오면
    # 그 태그가 최근 빌드로 덮여쓰인 것이므로 측정하기 전에 알아차릴 수 있다.
    docker images "coupon-service:$Tag" --format "   {{.Repository}}:{{.Tag}}   ID={{.ID}}   생성={{.CreatedSince}}"
}
else {
    # jib.to.tags 를 함께 넘기는 것이 중요하다. build.gradle.kts 의
    # `tags = setOf(project.version.toString())` 가 살아 있으면 새로 만든 이미지가
    # coupon-service:0.0.1-SNAPSHOT 태그까지 가져가면서, 기존 이미지를 가리키던 그 태그가
    # 새 이미지로 옮겨간다. 구현을 비교하려고 태그를 나누는 건데 기준을 잃게 된다.
    #
    # tar 경로도 태그별로 나눈다. 기본값(build/jib-image.tar)을 쓰면 매번 덮어쓴다.
    #
    # 태스크명 앞의 `:` 는 루트 프로젝트만 가리킨다. 빼면 안 된다 — settings.gradle.kts 가
    # gateway 를 include 하고 gateway 에도 jib 플러그인이 붙어 있어서, 경로 없는 jibBuildTar 는
    # 서브프로젝트에서도 돈다. 그러면 아래 -Djib.to.image=coupon-service:$Tag 가 게이트웨이
    # 빌드에까지 먹는다 (게이트웨이 이미지는 :gateway:jibBuildTar 로 따로 만든다).
    Invoke-Step "이미지 tar 빌드 (jibBuildTar) — coupon-service:$Tag" {
        .\gradlew.bat :jibBuildTar `
            "-Djib.to.image=coupon-service:$Tag" `
            "-Djib.to.tags=$Tag" `
            "-Djib.outputPaths.tar=build/jib-$Tag.tar" `
            --console=plain
    }

    Invoke-Step "Docker 에 이미지 로드" { docker load -i "build\jib-$Tag.tar" }
}

# compose 가 읽을 태그를 남긴다. 셸 환경변수로 하면 셸을 벗어나는 순간 사라져서,
# 다른 스크립트가 docker compose up 을 부를 때 컨테이너가 기본 태그로 조용히 되돌아간다.
# .env 는 compose 가 자동으로 읽으므로 PowerShell / Git Bash 어디서 부르든 일관된다.
Write-Host ""
Write-Host "==> 이미지 태그 기록 (.env)" -ForegroundColor Cyan
Set-Content -LiteralPath '.env' -Value "COUPON_IMAGE_TAG=$Tag" -Encoding ASCII
Write-Host "COUPON_IMAGE_TAG=$Tag"

Invoke-Step "compose 기동" { docker compose up -d }

Write-Host ""
Write-Host "==> 컨테이너 상태" -ForegroundColor Cyan
docker compose ps

Write-Host ""
Write-Host "완료. 앱: http://localhost:8080  (이미지: coupon-service:$Tag)" -ForegroundColor Green
Write-Host "로그: docker compose logs -f coupon-service" -ForegroundColor DarkGray
Write-Host "다른 구현으로 전환: .\build-and-run.ps1 -Tag <태그>" -ForegroundColor DarkGray

if ($Logs) {
    Write-Host ""
    docker compose logs -f coupon-service
}
