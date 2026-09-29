# 선착순 쿠폰 발급 — 동시성 결함을 재현하고, 구현을 바꿔가며 잰 기록

아키텍쳐를 공부하다 선착순 쿠폰 발급에서 생기는 **과발급·중복발급을 일부러 재현**한 뒤,
구현을 **이미지 태그 단위로 한 변수씩** 바꾸면서 매 단계를 같은 k6 하네스로 측정한 학습 프로젝트입니다.

> 강의 「<트래픽 급증을 견디는 서버 시스템 설계 - Coupon 발급 서비스>」를 따라가며 구현했고, 측정 하네스(Windows 포팅)·분석 문서는 직접 작성했습니다.

**Stack** — Kotlin · Spring Boot 4.1 (Java 25) · MySQL 8.4 · Redis 8 (Lua) · Kafka 3.8 · Caffeine · ShedLock · Spring Cloud Gateway · k6 · Docker Compose

---

## 무엇을 했나

요청이 지나가는 순서대로 다섯 도메인으로 나눴습니다. 도메인마다 구조 그림과 "문제 → 시도 → 결과 → 남은 과제" 가 따로 있습니다.

| 도메인 | 한 일 | 핵심 결과 |
|---|---|---|
| [01. 진입 제어](docs/domains/01-entry.md) | 게이트웨이 rate limit + 대기실(ShedLock) | 발급 API 도달 20,000 → **2,100**, 서버 2대에도 **100/s** · 어뷰저 2,001건 중 **65건만** 통과, 정상 차단 **0** |
| [02. 발급 판정](docs/domains/02-issue.md) | 과발급 재현 → 비관적 락 → Redis Lua → 쓰기를 큐 뒤로 | 과발급 7,552장의 원인이 **카운터 lost update** 임을 규명 · 처리량 ~290 → **~4,000건/s** · 발급 p99 705ms → **5.6ms** |
| [03. 발급 기록](docs/domains/03-write.md) | Kafka 워커, 실패 주입, DLT | 컨슈머 3배에도 안 빨라진 원인이 **워커 안의 단일 행 UPDATE** 임을 확정 · 발행·소비 실패를 직접 일으켜 "200 을 받았는데 사라지는 발급" 재현 |
| [04. 조회 캐시](docs/domains/04-cache.md) | read-through → single-flight → SWR → Caffeine L1 | DB 조회 15,001 → **27**, p99 747ms → **1.66ms** · 매진 요청 비용의 **36%가 불필요한 `@Transactional`** |
| [05. 정합성](docs/domains/05-consistency.md) | Redis ↔ DB 대사, 워터마크 | 고칠 수 있는 것만 자동 보정, DB 측 불일치는 **알람만** · 대사가 불일치를 **구조적으로 못 잡던** 결함 발견 |

**가장 크게 배운 것.** 병목은 없어지지 않고 옮겨 다녔습니다. `coupon` 단일 행 UPDATE 를 요청 경로에서 빼자 처리량이 10배가 됐고,
쓰기를 큐 뒤로 미루자 같은 UPDATE 가 워커 안에서 다시 상한이 됐습니다. 추측으로 고치지 않고 **태그마다 한 가지만 바꿔 측정으로 가른 것**이 이 프로젝트의 방식입니다.

## 어떻게 쟀나

- **트랙 다섯 개**(정확성 · 응답시간 · 효율 · 정합성 · 가용성)가 각각 한 줄 스크립트로 돕니다 — 리셋 · 쿠폰 생성 · k6 · 검증까지.
- **구현 = 이미지 태그.** 이전 구현을 언제든 다시 띄워 같은 조건으로 재측정합니다. 하네스는 DB/Redis 를 건드리기 전에 **재려는 기능이 그 이미지에 있는지** 먼저 확인합니다.
- **숫자를 믿는 조건.** `checks` 100%, 연결 실패(`status 0`) 분리, 워밍업 버림, 분포 통째로 읽기, 브로커 발행 총량 대조(30,003 정확히 일치).

---

## 실행

필요한 것: Docker, JDK 25 (k6 은 compose 의 컨테이너로 돈다).

```powershell
# 빌드 + 기동 (구현은 브랜치가 아니라 이미지 태그로 나눈다)
.\build-and-run.ps1 -Tag lua-pool
.\build-and-run.ps1 -Tag naive -NoBuild     # 이미 있는 이미지로 전환만

# 측정 (리셋·쿠폰 생성·k6·검증이 한 줄에 들어 있다)
.\scripts\concurrency\windows\load-test.ps1 over_issuance   # 정확성
.\scripts\response\windows\run.ps1                          # 응답시간
.\scripts\efficiency\windows\run.ps1                        # 효율
.\scripts\consistency\windows\run-v2.ps1                    # 정합성
.\scripts\availability\windows\run.ps1                      # 가용성
```

macOS/Linux 는 `./build-and-run.sh --tag <태그>` 와 각 트랙의 `run.sh`.
`gradlew jibDockerBuild` 는 교착에 빠지므로 쓰지 않는다 — [`jib-docker-build-troubleshooting.md`](docs/jib-docker-build-troubleshooting.md).
compose 의 비밀번호는 로컬 개발용이다.

각 단계의 소스는 git 태그 `stage/*` 로 남아 있다.

---

## 문서 지도

| 문서 | 내용 |
|---|---|
| [`docs/domains/`](docs/domains/01-entry.md) | **도메인별 구조 그림 + 한 일 + 남은 과제.** 처음 읽을 곳 |
| [`architecture.md`](docs/architecture.md) | 요청 흐름, 파일 지도, 구현별 차이, 하네스, 밟은 함정 |
| [`flow-diagrams.md`](docs/flow-diagrams.md) | 동기·비동기 경로와 두 저장소의 역할, 정합성·가용성 요약 |
| [`learning-notes.md`](docs/learning-notes.md) | 측정에서 얻은 것을 개념 단위로 정리 |
| [`load-test-k6.md`](docs/load-test-k6.md) · [`-response`](docs/load-test-response.md) · [`-efficiency`](docs/load-test-efficiency.md) | 측정 결과와 해석 (§1–§22, 세 파일에 걸쳐 이어짐) |
| [`consistency-track.md`](docs/consistency-track.md) · [`availability-track.md`](docs/availability-track.md) | 대사 검증 · 대기실/게이트웨이 |
| [`domain-model.md`](docs/domain-model.md) · [`db-schema.md`](docs/db-schema.md) | 도메인과 테이블 |
