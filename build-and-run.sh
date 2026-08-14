#!/usr/bin/env bash
#
# 이미지 tar 빌드 -> Docker 로드 -> compose 기동. (Git Bash / WSL 용)
#
# jibDockerBuild 는 Jib 3.4.4 의 `docker info` 교착 때문에 무한정 멈추므로
# Docker CLI 를 타지 않는 jibBuildTar + docker load 조합을 쓴다.
# 자세한 내용은 docs/jib-docker-build-troubleshooting.md 참고.
#
# 사용법:
#   ./build-and-run.sh                    빌드하고 컨테이너를 띄운 뒤 상태 출력
#   ./build-and-run.sh --tag pessimistic  해당 태그로 빌드/기동 (구현 비교용)
#   ./build-and-run.sh --logs             위 + 앱 로그 따라가기
#   ./build-and-run.sh --stop-daemon      Gradle 데몬이 꼬였을 때만

set -euo pipefail

# 어느 디렉터리에서 실행하든 프로젝트 루트 기준으로 동작하게 한다
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
    cat <<'EOF'
이미지 tar 빌드 -> Docker 로드 -> compose 기동.

사용법:
  ./build-and-run.sh                    빌드하고 컨테이너를 띄운 뒤 상태 출력
  ./build-and-run.sh --tag pessimistic  해당 태그로 빌드/기동 (구현 비교용)
  ./build-and-run.sh --logs             위 + 앱 로그 따라가기
  ./build-and-run.sh --stop-daemon      Gradle 데몬이 꼬였을 때만

  ./build-and-run.sh --tag naive --no-build   빌드 없이 기존 이미지로 전환만

--tag 를 주면 coupon-service:<태그> 로 빌드하고 그 태그를 .env 에 기록한다.
다른 태그의 이미지는 그대로 남으므로 구현끼리 오가며 비교할 수 있다.

이전 구현으로 되돌아갈 때는 반드시 --no-build 를 쓴다. 안 쓰면 "현재 소스" 를 빌드해
예전 이름표를 붙이므로, 알맹이는 최신 코드인데 이름만 예전인 이미지가 만들어진다.
EOF
}

logs=0
stop_daemon=0
no_build=0
tag=latest

while [ $# -gt 0 ]; do
    case "$1" in
        -l|--logs)        logs=1 ;;
        -s|--stop-daemon) stop_daemon=1 ;;
        -n|--no-build)    no_build=1 ;;
        -t|--tag)
            shift
            [ $# -gt 0 ] || { echo "--tag 에 값이 필요합니다 (--help 참고)" >&2; exit 2; }
            tag="$1"
            ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

if [ "$stop_daemon" -eq 1 ] && [ "$no_build" -eq 0 ]; then
    step "Gradle 데몬 정지"
    ./gradlew --stop
fi

if [ "$no_build" -eq 1 ]; then
    # 이전 구현으로 되돌아갈 때 쓰는 경로. 빌드하지 않으므로 이미지의 알맹이가
    # 그대로 보존된다. 대신 "쓰려는 이미지가 진짜 있는지" 를 확인해야 한다.
    step "빌드 건너뜀 (--no-build) — 기존 이미지 사용"

    if ! docker image inspect "coupon-service:$tag" >/dev/null 2>&1; then
        printf '\033[31m!! coupon-service:%s 이미지가 없습니다.\033[0m\n' "$tag" >&2
        printf '\033[90m   있는 이미지:\033[0m\n' >&2
        docker images coupon-service --format "     {{.Repository}}:{{.Tag}}" >&2
        printf '\033[90m   새로 빌드하려면 --no-build 를 빼고 실행하세요.\033[0m\n' >&2
        exit 1
    fi

    # 생성 시각을 같이 보여준다. 예전 구현을 쓰려는데 "몇 분 전" 으로 나오면
    # 그 태그가 최근 빌드로 덮여쓰인 것이므로 측정하기 전에 알아차릴 수 있다.
    docker images "coupon-service:$tag" --format "   {{.Repository}}:{{.Tag}}   ID={{.ID}}   생성={{.CreatedSince}}"
else
    # jib.to.tags 를 함께 넘기는 것이 중요하다. build.gradle.kts 의
    # `tags = setOf(project.version.toString())` 가 살아 있으면 새로 만든 이미지가
    # coupon-service:0.0.1-SNAPSHOT 태그까지 가져가면서, 기존 이미지를 가리키던 그 태그가
    # 새 이미지로 옮겨간다. 구현을 비교하려고 태그를 나누는 건데 기준을 잃게 된다.
    step "이미지 tar 빌드 (jibBuildTar) — coupon-service:$tag"
    ./gradlew jibBuildTar \
        "-Djib.to.image=coupon-service:$tag" \
        "-Djib.to.tags=$tag" \
        "-Djib.outputPaths.tar=build/jib-$tag.tar" \
        --console=plain

    step "Docker 에 이미지 로드"
    docker load -i "build/jib-$tag.tar"
fi

# compose 가 읽을 태그를 남긴다. 셸 환경변수로 하면 셸을 벗어나는 순간 사라져서,
# 다른 스크립트가 docker compose up 을 부를 때 컨테이너가 기본 태그로 조용히 되돌아간다.
step "이미지 태그 기록 (.env)"
echo "COUPON_IMAGE_TAG=$tag" > .env
cat .env

step "compose 기동"
docker compose up -d

step "컨테이너 상태"
docker compose ps

printf '\n\033[32m완료. 앱: http://localhost:8080  (이미지: coupon-service:%s)\033[0m\n' "$tag"
printf '\033[90m로그: docker compose logs -f coupon-service\033[0m\n'
printf '\033[90m다른 구현으로 전환: ./build-and-run.sh --tag <태그>\033[0m\n'

if [ "$logs" -eq 1 ]; then
    echo
    docker compose logs -f coupon-service
fi
