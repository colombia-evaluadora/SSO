# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile del ai-control-service.
#
# Se copian TODOS los pom.xml porque el pom padre los lista en
# <modules>; recien despues `mvn -pl ai-control-service -am` resuelve
# solo lo que este modulo necesita (common). Sin esas copias el paso
# offline falla con "Child module ... does not exist".

FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /workspace

COPY pom.xml ./
COPY eurekaserver/pom.xml eurekaserver/
COPY common/pom.xml common/
COPY auth-center/pom.xml auth-center/
COPY api-gateway/pom.xml api-gateway/
COPY file-service/pom.xml file-service/
COPY hello-service/pom.xml hello-service/
COPY sso-admin/pom.xml sso-admin/
COPY query-service/pom.xml query-service/
COPY provisioner/pom.xml provisioner/
COPY notification-service/pom.xml notification-service/
COPY reporting-service/pom.xml reporting-service/
COPY ai-control-service/pom.xml ai-control-service/

RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl ai-control-service -am dependency:go-offline -q

COPY common/src common/src
COPY ai-control-service/src ai-control-service/src
RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl ai-control-service -am clean package -DskipTests -q

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

RUN groupadd --system --gid 10001 app &&     useradd  --system --uid 10001 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/ai-control-service/target/ai-control-service.jar /app/app.jar

USER app
EXPOSE 8088

ENTRYPOINT ["java",     "-XX:+UseContainerSupport",     "-XX:MaxRAMPercentage=75",     "-Djava.security.egd=file:/dev/./urandom",     "-jar", "/app/app.jar"]
