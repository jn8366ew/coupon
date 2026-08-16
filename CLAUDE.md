# coupon

선착순 쿠폰 발급의 **동시성 결함을 일부러 재현하고, 구현을 바꿔가며 측정·비교하는 학습 프로젝트.**
Spring Boot 4.1 / Kotlin / MySQL / Redis, 부하 테스트는 k6.

**구조·함정·측정 하네스는 [`docs/architecture.md`](docs/architecture.md) 를 먼저 읽을 것.**
측정 결과와 해석은 트랙별로 세 파일 — 정확성 [`docs/load-test-k6.md`](docs/load-test-k6.md) §1–§12,
응답시간 [`docs/load-test-response.md`](docs/load-test-response.md) §13–§17,
효율 [`docs/load-test-efficiency.md`](docs/load-test-efficiency.md) §18–§22.
**절 번호는 세 파일에 걸쳐 이어진다.**
거기서 얻은 것을 개념으로 정리한 것은 [`docs/learning-notes.md`](docs/learning-notes.md).

## 규칙

- **빌드·기동은 `.\build-and-run.ps1 -Tag <태그>` 로 한다.** `gradlew jibDockerBuild` 는 교착에 빠진다.
  이전 구현으로 되돌아갈 때는 `-NoBuild` 를 반드시 붙인다 (안 붙이면 예전 이미지가 최신 코드로 덮인다).
- **구현은 브랜치가 아니라 이미지 태그로 나눈다** (`naive` / `pessimistic` / `lua` / …).
  선택한 태그는 `.env` 의 `COUPON_IMAGE_TAG` 에 기록되고 compose 가 읽는다.
- **스크립트는 세 트랙으로 나뉜다.** `scripts/concurrency/` 는 정확성(과발급·중복발급),
  `scripts/response/` 는 응답시간(P99), `scripts/efficiency/` 는 같은 결과를 내는 비용
  (DB 조회 횟수, 매진 후 헛도는 요청). 각 트랙 안에서 **mac 원본(bash)은 수정하지 않고**
  Windows 판은 `<트랙>/windows/` 에 따로 둔다.
- **부하 조건(rate, VU, USER_POOL)을 바꾸면 기존 측정 기록과 비교가 성립하지 않는다.**
  바꿔야 한다면 그 사실을 문서에 명시하고 전 구현을 다시 잰다.
- **재려는 기능이 그 이미지에 들어 있는지 먼저 확인한다.** 태그가 맞아도 그 태그가
  기능이 들어가기 전에 빌드됐을 수 있다. 새 기능을 재는 하네스는 라운드에 들어가기 전에
  기능의 존재를 직접 확인하고(예: `GET /metrics/cache`), 없으면 **DB/Redis 를 건드리기 전에**
  빌드 커맨드를 안내하고 멈춘다. 러너가 빌드까지 하지는 않는다 — 태그 선택은 사람 몫이고
  `-NoBuild` 를 빼먹으면 예전 이미지가 덮인다. 자세한 건 `docs/architecture.md` §7.
- 측정은 한 줄로 돈다. 쿼리 로그 끄기·리셋·쿠폰 생성·k6·검증이 전부 그 안에 들어 있다.
  - 정확성: `.\scripts\concurrency\windows\load-test.ps1 <over_issuance|duplicate_issuance>`
  - 응답시간: `.\scripts\response\windows\run.ps1` (워밍업 1회 + 본 측정 1회)
  - 효율: `.\scripts\efficiency\windows\run.ps1` (`-Scenario policy|sellout`, 워밍업 1회 + 본 측정 1회)
- k6 결과에서 `checks` 가 100% 가 아니면 나머지 숫자는 읽지 않는다. 특히 `connected (not status 0)`.
  응답시간·효율 트랙은 `status 0` 을 지연 분포에서 빼므로 `status_conn_error` 를 같이 읽는다.
