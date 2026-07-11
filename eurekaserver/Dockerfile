# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the eurekaserver module.
#
# Stage 1 — build: uses the official maven:3.9-eclipse-temurin-21 image
# to build the executable jar. The whole project (parent + 4 modules)
# is copied so the reactor can resolve common/auth-center/api-gateway
# transitively. We restrict the reactor to the eurekaserver module
# (and its required deps) to keep the build graph small.
#
# Stage 2 — runtime: a slim JRE 21 base. The fat-jar from the build
# stage is the only artifact we keep.

FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /workspace

# Copy parent POM and every module's POM first so the dependency
# graph is fully resolvable. This layer is cached as long as the
# POMs don't change, so source-only edits don't trigger a fresh
# dependency download.
COPY pom.xml ./
COPY eurekaserver/pom.xml eurekaserver/
COPY common/pom.xml common/
COPY auth-center/pom.xml auth-center/
COPY api-gateway/pom.xml api-gateway/
COPY hello-service/pom.xml hello-service/
COPY sso-admin/pom.xml sso-admin/
COPY query-service/pom.xml query-service/
COPY provisioner/pom.xml provisioner/
COPY notification-service/pom.xml notification-service/

# Pre-resolve dependencies (offline) so the actual build doesn't
# re-download them on every source change. `-pl` restricts the
# reactor to eurekaserver + its deps.
RUN mvn -B -ntp -pl eurekaserver -am dependency:go-offline -q

# Now copy the source and build the jar.
COPY eurekaserver/src eurekaserver/src
RUN mvn -B -ntp -pl eurekaserver -am clean package -DskipTests -q

# ---- runtime stage ----
FROM eclipse-temurin:25-jre
WORKDIR /app

# Non-root user. UID 1000 matches the typical "developer" user in
# most Linux distros, and gives the container something to bind
# mounted volumes as without root.
RUN groupadd --system --gid 10001 app && \
    useradd  --system --uid 10001 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/eurekaserver/target/eurekaserver.jar /app/app.jar

USER app
EXPOSE 8761

# Use exec form so the JVM receives SIGTERM on `docker stop` and
# graceful-shutdown has a chance to run.
ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]
