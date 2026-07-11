# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the query-service module.
#
# We COPY every module's pom.xml because the parent pom lists
# all of them in <modules>; `mvn -pl query-service -am` then
# resolves only query-service's actual deps (common) and leaves
# the others alone. Without those COPY lines the offline step
# fails with "Child module ... does not exist".

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

RUN mvn -B -ntp -pl query-service -am dependency:go-offline -q

COPY common/src common/src
COPY query-service/src query-service/src
RUN mvn -B -ntp -pl query-service -am clean package -DskipTests -q

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

RUN groupadd --system --gid 10001 app && \
    useradd  --system --uid 10001 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/query-service/target/query-service.jar /app/app.jar

USER app
EXPOSE 8084

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]