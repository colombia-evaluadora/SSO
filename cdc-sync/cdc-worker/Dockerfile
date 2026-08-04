# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the cdc-worker module.
#
# Mirrors cdc-capture/Dockerfile and the SSO reference modules
# (auth-center, provisioner): two stages, dependency layer caching,
# non-root runtime user (uid 10001), container-aware JVM flags.
#
# Build context is `./cdc-sync` (see docker-compose.yml), so the
# paths below are relative to that root.

# ----- stage 1: build the fat jar -----
FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /workspace

# Copy every module's pom.xml FIRST. The parent pom lists all of them
# in <modules>; `mvn -pl cdc-worker -am` then resolves only
# cdc-worker's actual deps (cdc-common) and leaves the others alone.
# Without these COPY lines the offline step fails with
# "Child module ... does not exist".
COPY pom.xml ./
COPY cdc-common/pom.xml cdc-common/
COPY cdc-capture/pom.xml cdc-capture/
COPY cdc-worker/pom.xml cdc-worker/

# Warm the local Maven repo with the dependency graph. This layer is
# invalidated only when one of the pom.xml files above changes — once
# cached, a source-only edit doesn't re-download the world.
RUN mvn -B -ntp -pl cdc-worker -am dependency:go-offline -q

# Copy sources LAST (most-frequently-changing layer). cdc-common has
# to come first because cdc-worker depends on it; `mvn -am` then
# compiles cdc-common and links it into cdc-worker's fat jar in
# the next step.
COPY cdc-common/src cdc-common/src
COPY cdc-worker/src cdc-worker/src

# Spring Boot's `repackage` goal (default during `package`) renames
# the empty pre-repackage jar to `*.jar.original` and writes the
# fat jar as `target/app.jar` (the pom pins `<finalName>app</finalName>`
# so the COPY below resolves to a single file, not a glob).
RUN mvn -B -ntp -pl cdc-worker -am clean package -DskipTests -q

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
COPY --from=build --chown=app:app /workspace/cdc-worker/target/app.jar /app/app.jar

USER app
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
