# Docker 이미지 빌드 트러블슈팅 기록

`.\gradlew.bat jibDockerBuild` 로 컨테이너 이미지를 만들려다 겪은 문제들과 해결 과정 기록.
2026-08-12.

## 환경

| 항목 | 값 |
|---|---|
| OS / CPU | Windows 11 Pro / **AMD64** |
| Docker | Docker Desktop, Engine 29.1.2 (WSL2 백엔드) |
| Gradle | 9.5.1 |
| Kotlin | 2.3.21 |
| Spring Boot | 4.1.0 |
| Java toolchain | 25 |
| Jib | **3.4.4** |

## TL;DR

문제 5개가 겹쳐 있었다. 앞의 4개는 금방 드러났지만, 마지막 하나가 **에러 없이 27분씩 멈추는** 형태라 진단에 가장 오래 걸렸다.

| # | 증상 | 원인 | 해결 |
|---|---|---|---|
| 1 | IDE 빨간줄 | `buildscript` 오타 (`bulidscript`) | 철자 수정 |
| 2 | `compileKotlin` 실패 | 블록 바디 함수에 `return` 없음 | 표현식 바디(`=`)로 변경 |
| 3 | 빌드가 수 분간 느림 | jib `platforms` 가 `arm64` (호스트는 amd64) | `platforms` 블록 제거 |
| 4 | `invalid compose project` | compose에 최상위 `volumes:` 선언 누락 | 선언 추가 |
| 5 | **에러 없이 27분+ 멈춤** | **Jib 3.4.4 가 `docker info` 자식 프로세스에서 교착** | `jibDockerBuild` → `jibBuildTar` + `docker load` |

---

## 1. `buildscript` 오타

**증상** — `build.gradle.kts` 1행이 IDE에서 빨간색.

```kotlin
bulidscript {   // ← 오타
	dependencies { classpath("org.ow2.asm:asm:9.8") }
}
```

**원인** — Gradle Kotlin DSL은 정적 타입 기반이라 `Project` 스코프에 없는 이름은 미해결 참조가 된다.

**주의** — 빌드를 막지는 않았지만, 그 상태에서는 `classpath(...)` 의존성이 실제로 buildscript classpath에 올라가지 않는다. "빌드가 되니까 괜찮다"가 아니다.

---

## 2. Missing return statement

**증상**

```
UserIssuanceController.kt:28:5 Missing return statement.
IssuanceService.kt:47:5 Missing return statement.
```

**원인** — Kotlin에서 중괄호 블록 바디는 **마지막 표현식이 자동 반환되지 않는다.** 자동 반환은 `=` 표현식 바디에서만 일어난다.

```kotlin
// 잘못됨 — 반환값 없음
fun findByUser(userId: Long): List<Issuance> {
    issuanceRepository.findByUserIdOrderByIssuedAtDesc(userId)
}

// 방법 A — 표현식 바디 (한 줄 위임 함수에 관용적)
fun findByUser(userId: Long): List<Issuance> =
    issuanceRepository.findByUserIdOrderByIssuedAtDesc(userId)

// 방법 B — 블록 바디 + 명시적 return
fun findByUser(userId: Long): List<Issuance> {
    return issuanceRepository.findByUserIdOrderByIssuedAtDesc(userId)
}
```

---

## 3. jib `platforms` 가 arm64

**증상** — 빌드가 진행 표시 없이 수 분간 정체.

**원인** — 호스트는 AMD64인데 jib 설정이 arm64였다.

```kotlin
from {
	image = "eclipse-temurin:25-jre"
	platforms { platform { architecture = "arm64"; os = "linux" } }   // ← 문제
}
```

`eclipse-temurin:25-jre` 는 멀티아치 이미지라 arm64 매니페스트가 **실제로 존재한다.** 그래서 에러가 나지 않고, 조용히 arm64 레이어를 통째로 새로 받는다. 로컬 amd64 캐시는 하나도 재사용되지 않는다.

**확인 방법** — `-i` 로그에 이 줄이 찍힌다.

```
Searching for architecture=arm64, os=linux in the base image manifest list
```

**해결** — `platforms` 블록 제거. Jib은 기본적으로 base image의 amd64/linux 매니페스트를 쓴다.

설령 빌드가 끝나도 AMD64 머신에서 그 이미지는 실행되지 않는다 (`exec format error`).

> ARM 대상 이미지가 실제로 필요하면 `jibDockerBuild` 가 아니라 레지스트리로 푸시하는 `jib` 태스크를 써야 한다. `jibDockerBuild` 는 로컬 Docker 데몬에 로드하는 방식이라 멀티플랫폼을 지원하지 않는다.

---

## 4. compose `undefined volume`

**증상**

```
service "mysql" refers to undefined volume mysql-data: invalid compose project
```

**원인** — named volume은 최상위 `volumes:` 에 선언해야 한다. 선언 없이 `mysql-data:/var/lib/mysql` 만 쓰면 Compose가 거부한다.

**해결** — 파일 끝에 추가.

```yaml
volumes:
  mysql-data:
```

값이 비어 있는 건 정상 — "기본 로컬 볼륨을 알아서 만들어라"라는 뜻이고, 실제 볼륨 이름은 `coupon_mysql-data` 가 된다.

> `./` 없이 쓴 경로는 무조건 named volume으로 해석된다. 호스트 바인드를 의도했다면 `./mysql-data:/var/lib/mysql` 처럼 `./` 로 시작해야 한다.

---

## 5. (핵심) Jib 3.4.4 가 `docker info` 에서 교착

가장 오래 걸린 문제. **에러도, 로그도, 타임아웃도 없이** 무한정 멈춘다.

### 증상

빌드가 항상 이 지점에서 멈췄다.

```
> Task :jibDockerBuild
Containerizing application to Docker daemon as coupon-service, coupon-service:0.0.1-SNAPSHOT...
Building dependencies layer...
...
Container entrypoint set to [java, -cp, @/app/jib-classpath-file, com.example.coupon.CouponApplicationKt]
        ← 여기서 27분+ 정지. 진행률 표시는 83%에 고정.
```

### 진단 과정

**(a) Gradle 데몬 로그에서 실제 소요 시간 확인**

```powershell
# 최신 데몬 로그 찾기
ls $env:USERPROFILE\.gradle\daemon\9.5.1\*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

```
18:48:44  Daemon is about to start building
19:16:18  The daemon has finished executing the build      ← 27분 30초
19:16:18  Could not write message Success... to '/127.0.0.1:14929'
          java.nio.channels.ClosedChannelException          ← 클라이언트가 이미 끊김
```

**(b) Jib이 실제로 일하고 있는지 = 파일을 쓰고 있는지 확인**

Jib 캐시는 두 곳이다.

| 경로 | 용도 |
|---|---|
| `%LOCALAPPDATA%\Google\Jib\Cache\layers` | 레지스트리에서 받은 base image 레이어 |
| `%LOCALAPPDATA%\Google\Jib\Cache\local` | `docker://` 로 로컬 데몬에서 뽑은 base image |
| `build/jib-cache` | 앱 레이어 (의존성/리소스/클래스) |

```bash
find "$LOCALAPPDATA/Google/Jib/Cache" build/jib-cache -type f -newermt '-5 minutes' \
  -printf '%TH:%TM:%TS %12s %p\n' | sort -r | head
```

결과: **5분간 아무것도 쓰이지 않음.** 느린 게 아니라 블록된 상태라는 뜻.

**(c) 어디서 블록됐는지 — 자식 프로세스의 커맨드라인 확인**

이 한 줄이 결정적이었다.

```powershell
Get-CimInstance Win32_Process -Filter "Name='docker.exe'" |
  Select-Object ProcessId, CreationDate, CommandLine | Format-List
```

```
ProcessId    : 41308
CreationDate : 2026-08-12 19:24:19
CommandLine  : docker info -f "{{json .}}"
```

Jib이 띄운 `docker info` 자식 프로세스가 **15분 넘게 끝나지 않고** 살아 있었다. Jib은 이걸 기다리는 중이었다.

**(d) Docker 자체 문제인지 가르기**

같은 명령을 직접 실행:

```bash
time docker info -f '{{json .}}' > /dev/null    # → 1초, exit 0
```

Docker 데몬은 정상. **Jib이 그 프로세스를 다루는 방식**이 문제.

### 원인

`docker info -f "{{json .}}"` 의 출력이 **15,651 바이트**였다.

```bash
docker info -f '{{json .}}' | wc -c   # 15651
```

자식 프로세스의 stdout 파이프 버퍼를 넘기는 크기다. 부모(Jib)가 출력을 계속 읽어내지 않으면 자식은 write에서, 부모는 wait에서 서로를 기다리며 교착된다. 이 머신에 컨테이너 8개 + 이미지 12개가 떠 있어 `docker info` 출력이 유난히 컸던 것이 방아쇠로 보인다.

`jibDockerBuild` 는 Docker 데몬과 대화해야 하므로 이 호출을 피할 수 없다.

### 해결

**`jibDockerBuild` 대신 `jibBuildTar` + `docker load`.**
`jibBuildTar` 는 tar 파일만 만들고 Docker CLI를 **전혀 호출하지 않으므로** 교착 지점 자체가 없다.

```powershell
.\gradlew.bat jibBuildTar --console=plain
docker load -i build\jib-image.tar
```

### 시도했지만 소용없었던 것

**`docker pull` 로 base image 미리 받기 → 무효.**
Jib은 base image를 **로컬 Docker 데몬에서 가져오지 않는다.** 레지스트리에서 자기 전용 캐시(`%LOCALAPPDATA%\Google\Jib\Cache`)로 따로 받는다. `docker pull` 은 jib 빌드에 아무 영향이 없다.

**`from.image = "docker://eclipse-temurin:25-jre"` → 부분적으로만 효과.**
`docker://` 접두사는 로컬 Docker 데몬의 이미지를 base로 쓰게 한다. base image 확보 자체는 성공했지만(19:24:22에 `Cache/local` 로 3개 레이어 기록), 결국 같은 `docker info` 교착에 걸렸다. Docker CLI를 타는 경로라 근본 해결이 아니다.

---

## 최종 설정

### `build.gradle.kts`

```kotlin
jib {
	from {
		image = "eclipse-temurin:25-jre"
	}
	to {
		image = "coupon-service"
		tags = setOf(project.version.toString())
	}
	container {
		mainClass = "com.example.coupon.CouponApplicationKt"
		ports = listOf("8080")
		creationTime.set("USE_CURRENT_TIMESTAMP")
	}
}
```

- `platforms` 없음 → 호스트와 같은 amd64 사용
- `mainClass` 명시 → Jib의 클래스 파일 전수 스캔 단계 제거
  (없으면 `Searching for main class... Add a 'mainClass' configuration to 'jib' to improve build speed.` 경고)
- `to.image` 에 태그가 없으면 `:latest` 가 기본으로 붙으므로 `tags` 에 `"latest"` 를 또 넣을 필요 없음
- `creationTime.set(...)` 은 Kotlin DSL에서 올바른 형태 (`Property<String>`)

### `docker-compose.yml`

```yaml
services:
  mysql:
    image: mysql:8.4
    # ...
    volumes:
      - mysql-data:/var/lib/mysql

volumes:
  mysql-data:
```

---

## 실행 절차

```powershell
# 1. DB 기동
docker compose up -d
docker compose ps                      # STATUS 가 Up ... (healthy) 여야 함

# 2. 이미지 빌드
.\gradlew.bat jibBuildTar --console=plain
docker load -i build\jib-image.tar
docker images coupon-service           # latest, 0.0.1-SNAPSHOT 두 태그 확인

# 3. 앱 실행
docker run --rm -p 8080:8080 `
  --network coupon_default `
  -e SPRING_DATASOURCE_URL="jdbc:mysql://mysql:3306/coupon" `
  coupon-service:0.0.1-SNAPSHOT

# 4. 확인
curl.exe -i "http://localhost:8080/api/v1/users/me/issuances" -H "X-User-Id: 1"
```

`SPRING_DATASOURCE_URL` 을 넘기는 이유: `application.yaml` 의 기본값이 `jdbc:mysql://localhost:3306/coupon` 인데, 컨테이너 안에서 `localhost` 는 **그 컨테이너 자신**이다. MySQL 컨테이너를 가리키려면 compose 네트워크(`coupon_default`)에 붙이고 호스트명을 서비스 이름(`mysql`)으로 줘야 한다.

### 결과

```
REPOSITORY       TAG              IMAGE ID       CREATED
coupon-service   0.0.1-SNAPSHOT   c3b2111ea556   ...
coupon-service   latest           c3b2111ea556   ...

arch=amd64 os=linux
entrypoint=[java -cp @/app/jib-classpath-file com.example.coupon.CouponApplicationKt]
ports=map[8080/tcp:{}]
```

---

## 교훈

**1. 진행률 표시를 신뢰하지 말 것.**
Jib의 진행률은 네트워크나 자식 프로세스에서 멈춰도 그 자리에 그대로 머문다. 83%에서 27분을 보냈다. 판단은 **부수 효과**로 해야 한다 — 파일이 쓰이고 있는가, 이미지가 생겼는가.

**2. "느린 것"과 "멈춘 것"은 캐시 타임스탬프로 가른다.**

```bash
find <cache-dir> -type f -newermt '-5 minutes'
```

아무것도 안 나오면 일하는 중이 아니다.

**3. 멈춘 빌드는 자식 프로세스의 커맨드라인부터 본다.**

```powershell
Get-CimInstance Win32_Process -Filter "Name='docker.exe'" |
  Select-Object ProcessId, CreationDate, CommandLine | Format-List
```

`CreationDate` 가 몇 분 전인데 아직 살아 있으면 그게 범인이다.

**4. 도구가 조용히 성공하는 잘못된 설정이 가장 위험하다.**
arm64 지정은 에러를 내지 않았다. 멀티아치 이미지라 "요청대로" 동작했을 뿐이다. 에러가 없다는 것이 맞다는 뜻은 아니다.

**5. 원인을 하나 찾았다고 그게 유일한 원인은 아니다.**
arm64 문제는 실재했고 고칠 가치가 있었지만, 27분 정지의 원인은 처음부터 끝까지 `docker info` 교착이었다. 증상이 완전히 사라지기 전까지는 진단이 끝난 게 아니다.

## 남은 과제

- `application.yaml` 에 `spring.data.redis` 설정이 있으나 `build.gradle.kts` 에 Redis 스타터 의존성이 없다. 현재는 무시될 뿐이지만, 실제로 쓰려면 의존성과 compose 서비스를 함께 추가해야 한다.
- `creationTime = "USE_CURRENT_TIMESTAMP"` 는 매 빌드마다 이미지 다이제스트를 바꾼다. 재현 가능한 빌드가 필요해지면 재검토.
- CI 환경에서는 익명 Docker Hub pull이 rate limit 대상이다. `docker login` 이 사실상 필수.
- Jib 상위 버전에서 `docker info` 교착이 고쳐졌는지 확인해 볼 것. 고쳐졌다면 `jibDockerBuild` 로 되돌려 단계를 하나 줄일 수 있다.
