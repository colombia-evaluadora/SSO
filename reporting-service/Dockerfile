# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile del reporting-service.
#
# Se copian TODOS los pom.xml porque el pom padre los lista en
# <modules>; recien despues `mvn -pl reporting-service -am` resuelve
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

RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl reporting-service -am dependency:go-offline -q

COPY common/src common/src
COPY reporting-service/src reporting-service/src
RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl reporting-service -am clean package -DskipTests -q

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app

# Jasper dibuja el PDF con java.awt (medicion de texto, fuentes), asi
# que necesita las libs de fontconfig aunque no haya display. Sin esto
# el primer reporte muere con UnsatisfiedLinkError sobre libfontconfig.
# Las fuentes DejaVu cubren las tildes y la ñ; sin ninguna fuente
# instalada, Jasper cae a un default que las dibuja como cuadraditos.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libfreetype6 libfontconfig1 fontconfig fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 app && \
    useradd  --system --uid 10001 --gid app --home /app app

COPY --from=build --chown=app:app /workspace/reporting-service/target/reporting-service.jar /app/app.jar

USER app
EXPOSE 8087

# -Djava.awt.headless=true es obligatorio: Jasper usa java.awt para
# medir texto y sin display el arranque del primer reporte falla.
ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.awt.headless=true", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]
