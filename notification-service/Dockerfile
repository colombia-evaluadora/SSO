# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the notification-service module.
# Same pattern as auth-center/Dockerfile and sso-admin/Dockerfile —
# multi-stage, slim JRE runtime, non-root user. The jar name is
# notification-service.jar (matches the
# <finalName>${project.artifactId}</finalName> in pom.xml).
#
# We COPY every module's pom.xml because the parent pom lists
# all of them in <modules>; `mvn -pl notification-service -am`
# then resolves only notification-service's actual deps (common)
# and leaves the others alone. Without those COPY lines the
# offline step fails with "Child module ... does not exist".

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

RUN mvn -B -ntp -pl notification-service -am dependency:go-offline -q

COPY common/src common/src
COPY notification-service/src notification-service/src
RUN mvn -B -ntp -pl notification-service -am clean package -DskipTests -q

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

RUN groupadd --system --gid 1000 app && \
    useradd  --system --uid 1000 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/notification-service/target/notification-service.jar /app/app.jar

USER app
EXPOSE 8085

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]
