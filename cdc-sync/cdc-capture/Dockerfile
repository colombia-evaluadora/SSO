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

# Warm the local Maven repo with the dependency graph. This layer is
# invalidated only when one of the pom.xml files above changes — once
# cached, a source-only edit doesn't re-download the world.
RUN mvn -B -ntp -pl cdc-capture -am dependency:go-offline -q

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
RUN mvn -B -ntp -pl cdc-capture -am clean package -DskipTests -q

# ----- stage 2: minimal JRE runtime -----
FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

# uid/gid 10001 mirrors the SSO reference modules (auth-center,
# provisioner) and is guaranteed free across temurin bases — the
# `getent` guards make this idempotent against future base-image
# reshuffles.
RUN set -eux ; \
    if ! getent group 10001 >/dev/null ; then groupadd --system --gid 10001 app ; fi ; \
    if ! getent passwd app >/dev/null ; then \
        existing_gid=$(getent group 10001 | cut -d: -f3) ; \
        useradd --system --uid 10001 --gid $existing_gid --home /app app ; \
    fi

# --chown sets the owner in the same step; the COPY pulls only the
# fat jar from the build stage, leaving Maven, the JDK, and the local
# repo behind in the build image.
COPY --from=build --chown=app:app /workspace/cdc-capture/target/app.jar /app/app.jar

# Container runs as root on purpose. The named volume
# `cdc-capture-offsets` is mounted at /var/cdc-capture/offsets and
# is created root-owned by Docker's mount helper (the `local` driver
# chowns nothing on volume creation, and compose's `:U` flag only
# applies to anonymous volumes, not named ones). Debezium's
# FileOffsetBackingStore writes offsets.dat there on every flush,
# and the JVM has to be able to create/replace that file. Running
# root is acceptable for cdc-capture because the container has no
# public ingress — only the api-gateway is reachable from outside
# the compose network, and it talks to cdc-capture over RabbitMQ/AMQP
# (same trust-model argument as the `provisioner` service, which
# also runs as root because it needs /var/run/docker.sock).
EXPOSE 8081

# Container-aware JVM: pick a sane heap from the cgroup limit instead
# of the host's total RAM (we don't want every replica claiming
# 75% of the box), and use /dev/urandom via the egd hint so JWT
# signing doesn't block on first-request entropy.
ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]
