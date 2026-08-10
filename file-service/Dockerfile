# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for file-service.
# Same shape as the other services: maven build →
# eclipse-temurin JRE runtime.
#
# Every module pom is copied before the sources so the
# dependency layer is cached: the reactor needs to resolve
# the whole tree even when only file-service is built.

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
COPY file-service/pom.xml file-service/

RUN mvn -B -ntp -pl file-service -am dependency:go-offline -q

COPY common/src common/src
COPY file-service/src file-service/src
RUN mvn -B -ntp -pl file-service -am clean package -DskipTests -q

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

RUN groupadd --system --gid 10001 app && \
    useradd  --system --uid 10001 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/file-service/target/file-service.jar /app/app.jar

USER app
EXPOSE 8086

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]