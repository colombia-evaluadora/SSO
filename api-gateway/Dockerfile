# syntax=docker/dockerfile:1.7-labs
#
# Multi-stage Dockerfile for the api-gateway module.
#
# Stage 1 (node-spa): builds the admin-ui SPA with Vite and stages
#                     its `dist/` for the copy below. Skipped via
#                     target=java-only if you want a backend-only image.
#
# Stage 2 (java-build): runs `mvn package` for the api-gateway module.
#                       We `COPY` the SPA dist into the resources tree
#                       before `package` so it ends up inside the jar.
#
# Stage 3 (jre):       JRE recortada con jlink (misma lista que
#                      docker/java-service.Dockerfile).
#
# Stage 4 (runtime):   debian-slim + la JRE + el jar extraido en capas.

ARG JDK_IMAGE=eclipse-temurin:25-jdk-jammy
ARG RUNTIME_BASE=debian:13-slim

# ----- stage 1: build the SPA -----
FROM node:20-alpine AS node-spa
WORKDIR /spa

# VITE_APP_NAME scopes the SPA's sidebar to one App on the
# backend (the menuApi.getMyMenu wrapper forwards it as
# ?app=<name> on GET /sso-admin/myMenu). Default to empty so
# an unset value leaves the SPA un-scoped — keeps dev/CI
# builds working without a value, while production deploys
# set it via docker-compose.yml build.args.
ARG VITE_APP_NAME=""
ENV VITE_APP_NAME=$VITE_APP_NAME

# Copy manifests first so dependency install is cached when only the
# source changes. The lockfile is committed at admin-ui/.
COPY admin-ui/package.json admin-ui/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY admin-ui/ ./
RUN npm run build

# ----- stage 2: build the gateway jar -----
FROM maven:3.9-eclipse-temurin-25 AS java-build
WORKDIR /workspace

# Todos los pom.xml del repo con su ruta: un modulo nuevo no obliga a
# tocar este fichero (ver docker/java-service.Dockerfile).
COPY --parents pom.xml */pom.xml common/*/pom.xml ./

RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl api-gateway -am dependency:go-offline -q

COPY --parents common/*/src ./
COPY api-gateway/src api-gateway/src

# Stage the SPA dist into the gateway's static resources. The
# AdminUiRouter bean reads `static/admin/...` from the classpath.
# We do this BEFORE `mvn package` so the files end up in the fat jar.
COPY --from=node-spa /spa/dist/ api-gateway/src/main/resources/static/admin/

RUN mvn -B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504 -pl api-gateway -am clean package -DskipTests -q \
    && java -Djarmode=tools -jar api-gateway/target/api-gateway.jar \
        extract --layers --launcher --destination /extraido

# ----- stage 3: JRE recortada -----
# java.se entero + los jdk.* que jdeps no ve (ver el Dockerfile comun).
FROM ${JDK_IMAGE} AS jre
RUN jlink \
        --add-modules java.se,jdk.unsupported,jdk.jfr,jdk.management,jdk.net,jdk.localedata,jdk.charsets,jdk.crypto.cryptoki,jdk.zipfs,jdk.naming.dns,jdk.security.jgss,jdk.xml.dom,jdk.management.agent,jdk.jcmd \
        --strip-debug --no-man-pages --no-header-files --compress=zip-6 \
        --output /jre

# ----- stage 4: runtime -----
# debian-slim y no distroless/Alpine: glibc para el transporte epoll nativo
# de Netty y bash para el healthcheck del compose.
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
    useradd --system --uid 10001 --gid app --home /app app

COPY --from=jre /jre ${JAVA_HOME}

# De lo que menos cambia a lo que mas: un cambio de codigo (o del SPA) solo
# sube la capa application.
COPY --from=java-build --chown=app:app /extraido/dependencies/ ./
COPY --from=java-build --chown=app:app /extraido/spring-boot-loader/ ./
COPY --from=java-build --chown=app:app /extraido/snapshot-dependencies/ ./
COPY --from=java-build --chown=app:app /extraido/application/ ./

USER app
EXPOSE 8080

# Ajuste para un proxy reactivo, sobrescribible desde el compose:
#   UseCompactObjectHeaders (JDK 25): cabeceras de 8 bytes; el gateway crea
#     muchos objetos pequenos por peticion y el heap ocupado baja.
#   Xss512k: Netty usa pocos hilos (event loops) y no necesita pilas de 1 MB.
ENV JAVA_TOOL_OPTIONS="-XX:+UseCompactObjectHeaders -Xss512k"

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-XX:+ExitOnOutOfMemoryError", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "org.springframework.boot.loader.launch.JarLauncher"]
