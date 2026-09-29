// API 관문(Spring Cloud Gateway). 본 앱과 같은 Boot 4 계열을 사용한다.
// 빌드: .\gradlew.bat :gateway:jibBuildTar  ->  docker load -i gateway\build\jib-image.tar
// (jibDockerBuild 는 Jib 3.4.4 의 `docker info` 교착 때문에 멈춘다 — docs/jib-docker-build-troubleshooting.md)
// 태스크 경로의 `:gateway:` 를 빼면 루트의 coupon-service 빌드까지 같이 돈다.
plugins {
    kotlin("jvm") version "2.3.21"
    kotlin("plugin.spring") version "2.3.21"
    id("io.spring.dependency-management") version "1.1.7"
    id("com.google.cloud.tools.jib") version "3.4.4"
}

group = "com.apiece"
version = "0.0.1-SNAPSHOT"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

repositories {
    mavenCentral()
}

dependencyManagement {
    imports {
        // BOM 의 Kotlin 버전을 플러그인 버전에 맞춘다. 안 맞추면 증분 컴파일이 깨진다.
        mavenBom("org.springframework.boot:spring-boot-dependencies:4.0.7") {
            bomProperty("kotlin.version", "2.3.21")
        }
        mavenBom("org.springframework.cloud:spring-cloud-dependencies:2025.1.2")
    }
}

dependencies {
    implementation("org.springframework.cloud:spring-cloud-starter-gateway-server-webflux")
    // RedisRateLimiter 는 reactive Redis 필요. 저장소는 같은 Redis 재사용.
    implementation("org.springframework.boot:spring-boot-starter-data-redis-reactive")
    implementation("org.jetbrains.kotlin:kotlin-reflect")
    testImplementation("org.springframework.boot:spring-boot-starter-webflux-test")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

kotlin {
    compilerOptions {
        freeCompilerArgs.add("-Xjsr305=strict")
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
}

jib {
    from {
        // 본 앱과 같은 base 이미지 사용.
        // 강의 원본은 여기에 platforms { arm64 } 를 고정한다 (mac / Apple Silicon).
        // 이 머신은 Windows/amd64 이고 루트 build.gradle.kts 의 jib 에도 platforms 가 없다.
        // 고정해 두면 exec format error 로 컨테이너가 안 뜬다.
        image = "eclipse-temurin:25-jre"
    }
    to {
        image = "coupon-gateway"
        tags = setOf("latest")
    }
    container {
        mainClass = "com.apiece.gateway.GatewayApplicationKt"
        ports = listOf("8080")
        creationTime.set("USE_CURRENT_TIMESTAMP")
    }
}
