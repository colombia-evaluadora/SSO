# syntax=docker/dockerfile:1.7
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
# Stage 3 (runtime):   eclipse-temurin:25-jre + the fat jar.

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

RUN mvn -B -ntp -pl api-gateway -am dependency:go-offline -q

COPY common/src common/src
COPY api-gateway/src api-gateway/src

# Stage the SPA dist into the gateway's static resources. The
# AdminUiRouter bean reads `static/admin/...` from the classpath.
# We do this BEFORE `mvn package` so the files end up in the fat jar.
COPY --from=node-spa /spa/dist/ api-gateway/src/main/resources/static/admin/

RUN mvn -B -ntp -pl api-gateway -am clean package -DskipTests -q

# ----- stage 3: runtime -----
FROM eclipse-temurin:25-jre
WORKDIR /app

# uid/gid 1000 are usually already taken (e.g. eclipse-temurin:25-jre
# now ships a `temurin` user with uid/gid 1000). Pick 10001
# instead — guaranteed free across temurin bases, and only
# consumed by this image so collisions across the compose
# stack don't matter. The `getent` guards make this idempotent
# against future base-image reshuffles (the very same pattern
# Dockerfile.local has used since the colima 4GiB-VM fix).
RUN set -eux ; \
    if ! getent group 10001 >/dev/null ; then groupadd --system --gid 10001 app ; fi ; \
    if ! getent passwd app >/dev/null ; then \
        existing_gid=$(getent group 10001 | cut -d: -f3) ; \
        useradd --system --uid 10001 --gid $existing_gid --home /app app ; \
    fi

COPY --from=java-build --chown=app:app /workspace/api-gateway/target/api-gateway.jar /app/app.jar

USER app
EXPOSE 8080

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", "/app/app.jar"]
