# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the cdc-capture module.
#
# Same shape as the SSO reference modules (auth-center/Dockerfile,
# provisioner/Dockerfile): two stages, dependency layer caching,
# non-root runtime user, container-aware JVM flags.
#
# Build context is `./cdc-sync` (see docker-compose.yml), so the
# paths below are relative to that root.
#
# Runtime: misma receta que docker/java-service.Dockerfile (JRE de jlink
# sobre debian-slim, jar extraido en capas). La JVM corre como app (uid
# 10001); el arranque como root solo corrige el dueno del volumen de offsets.

ARG JDK_IMAGE=eclipse-temurin:25-jdk-jammy
ARG RUNTIME_BASE=debian:13-slim

# ----- JRE recortada (java.se + los jdk.* que jdeps no ve) -----
FROM ${JDK_IMAGE} AS jre
RUN jlink \
        --add-modules java.se,jdk.unsupported,jdk.jfr,jdk.management,jdk.net,jdk.localedata,jdk.charsets,jdk.crypto.cryptoki,jdk.zipfs,jdk.naming.dns,jdk.security.jgss,jdk.xml.dom,jdk.management.agent,jdk.jcmd \
        --strip-debug --no-man-pages --no-header-files --compress=zip-6 \
        --output /jre

# ----- stage 1: build the fat jar -----
FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /workspace

# Copy every module's pom.xml FIRST. The parent pom lists all of them
# in <modules>; `mvn -pl cdc-capture -am` then resolves only
# cdc-capture's actual deps (cdc-common) and leaves the others alone.
# Without these COPY lines the offline step fails with
# "Child module ... does not exist".
COPY pom.xml ./
COPY cdc-common/pom.xml cdc-common/
COPY cdc-capture/pom.xml cdc-capture/
COPY cdc-worker/pom.xml cdc-worker/
# cdc-generator is only consumed at build time by cdc-worker (see
# cdc-worker/Dockerfile). cdc-capture just needs the pom to exist so
# the parent reactor can resolve the new <module> entry without
# "Child module cdc-generator does not exist".
COPY cdc-generator/pom.xml cdc-generator/

# Warm the local Maven repo with the dependency graph. This layer is
# invalidated only when one of the pom.xml files above changes — once
# cached, a source-only edit doesn't re-download the world.
RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl cdc-capture -am dependency:go-offline -q

# Copy sources LAST (most-frequently-changing layer). cdc-common has
# to come first because cdc-capture depends on it; `mvn -am` then
# compiles cdc-common and links it into cdc-capture's fat jar in
# the next step.
COPY cdc-common/src cdc-common/src
COPY cdc-capture/src cdc-capture/src

# Spring Boot's `repackage` goal (default during `package`) renames
# the empty pre-repackage jar to `*.jar.original` and writes the
# fat jar as `target/app.jar` (the pom pins `<finalName>app</finalName>`
# so the COPY below resolves to a single file, not a glob).
RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl cdc-capture -am clean package -DskipTests -q \
    && java -Djarmode=tools -jar cdc-capture/target/app.jar \
        extract --layers --launcher --destination /extraido

# ----- stage 2: runtime -----
FROM ${RUNTIME_BASE}
WORKDIR /app

ENV JAVA_HOME=/opt/java/openjdk \
    LANG=C.UTF-8
ENV PATH="${JAVA_HOME}/bin:${PATH}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates tzdata; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system --gid 10001 app; \
    useradd --system --uid 10001 --gid app --home /app app; \
    install -d -o app -g app /var/cdc-capture/offsets

COPY --from=jre /jre ${JAVA_HOME}
COPY --from=build --chown=app:app /extraido/dependencies/ ./
COPY --from=build --chown=app:app /extraido/spring-boot-loader/ ./
COPY --from=build --chown=app:app /extraido/snapshot-dependencies/ ./
COPY --from=build --chown=app:app /extraido/application/ ./

# El volumen con nombre cdc-capture-offsets nace con dueno root y los que ya
# existen en los servidores tambien lo son: el arranque (root) le da el
# volumen a app y despues ejecuta la JVM como app con setpriv. No se usa un
# contenedor init aparte porque el redeploy en caliente recrea con --no-deps
# y no lo ejecutaria. En el compose el contenedor solo conserva CHOWN, SETUID
# y SETGID, y no-new-privileges.
COPY --chmod=0755 <<'EOF' /usr/local/bin/arranque
#!/bin/sh
set -eu
dir="${CDC_OFFSETS_DIR:-/var/cdc-capture/offsets}"
if [ "$(id -u)" = 0 ]; then
    mkdir -p "$dir"
    chown -R app:app "$dir"
    # Al cambiar a un uid no root el kernel vacia las capacidades efectivas y
    # no-new-privileges impide recuperarlas; recortar el bounding set exigiria
    # CAP_SETPCAP, que el contenedor no tiene.
    exec setpriv --reuid=app --regid=app --init-groups --inh-caps=-all -- "$@"
fi
exec "$@"
EOF
# Si el Dockerfile llega con CRLF (checkout en Windows), el shebang seria
# "/bin/sh\r" y el arranque fallaria con "no such file or directory".
RUN sed -i 's/\r$//' /usr/local/bin/arranque

EXPOSE 8081

# Container-aware JVM: pick a sane heap from the cgroup limit instead
# of the host's total RAM (we don't want every replica claiming
# 75% of the box), and use /dev/urandom via the egd hint.
ENTRYPOINT ["/usr/local/bin/arranque", "java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-XX:+ExitOnOutOfMemoryError", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "org.springframework.boot.loader.launch.JarLauncher"]
