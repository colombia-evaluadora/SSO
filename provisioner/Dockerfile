# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the provisioner sidecar.
# Same shape as query-service: maven build → eclipse-temurin
# JRE runtime. The provisioner is small (no DB, no
# security, no Eureka client) so the runtime image stays
# minimal.

FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /workspace

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

RUN mvn -B -ntp -pl provisioner -am dependency:go-offline -q

COPY common/src common/src
COPY provisioner/src provisioner/src
RUN mvn -B -ntp -pl provisioner -am clean package -DskipTests -q

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

RUN groupadd --system --gid 10001 app && \
    useradd  --system --uid 10001 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/provisioner/target/provisioner.jar /app/app.jar

# curl is the only tool this image needs at runtime — it
# talks to the Docker Engine API via curl --unix-socket.
# The base temurin JRE image ships with it, but pin it just
# in case a slim variant gets adopted later.
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

USER app
EXPOSE 9000

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]