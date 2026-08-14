# coupon

선착순 쿠폰 발급의 **동시성 결함을 일부러 재현하고, 구현을 바꿔가며 측정·비교하는 학습 프로젝트.**
Spring Boot 4.1 / Kotlin / MySQL / Redis, 부하 테스트는 k6.

**구조·함정·측정 하네스는 [`docs/architecture.md`](docs/architecture.md) 를 먼저 읽을 것.**
측정 결과와 해석은 [`docs/load-test-k6.md`](docs/load-test-k6.md).

## 규칙

- **빌드·기동은 `.\build-and-run.ps1 -Tag <태그>` 로 한다.** `gradlew jibDockerBuild` 는 교착에 빠진다.
  이전 구현으로 되돌아갈 때는 `-NoBuild` 를 반드시 붙인다 (안 붙이면 예전 이미지가 최신 코드로 덮인다).
- **구현은 브랜치가 아니라 이미지 태그로 나눈다** (`naive` / `pessimistic` / `lua` / …).
  선택한 태그는 `.env` 의 `COUPON_IMAGE_TAG` 에 기록되고 compose 가 읽는다.
- **`scripts/load/` (mac 원본) 는 수정하지 않는다.** Windows 판은 `scripts/windows/` 에 따로 있다.
- **부하 조건(rate, VU, USER_POOL)을 바꾸면 기존 측정 기록과 비교가 성립하지 않는다.**
  바꿔야 한다면 그 사실을 문서에 명시하고 전 구현을 다시 잰다.
- 측정은 `.\scripts\windows\load-test.ps1 <over_issuance|duplicate_issuance>` 한 줄로 돈다.
  쿼리 로그 끄기·리셋·쿠폰 생성·k6·검증이 전부 그 안에 들어 있다.
- k6 결과에서 `checks` 가 100% 가 아니면 나머지 숫자는 읽지 않는다. 특히 `connected (not status 0)`.
