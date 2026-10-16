# syntax=docker/dockerfile:1.7-labs
#
# Dockerfile unico de los servicios Java del reactor (todos menos
# api-gateway, que compila admin-ui dentro, y cdc-sync, que es otro reactor).
#
#   docker build -f docker/java-service.Dockerfile --build-arg MODULE=query-service .
#
# Por que no lista los pom.xml: `COPY --parents` copia todos los pom.xml del
# repo con su ruta, asi que un modulo nuevo no obliga a tocar este fichero.
# La capa de dependencias solo se invalida cuando cambia algun pom.xml.
#
# La imagen final lleva el jar extraido en capas de Spring Boot: un cambio de
# codigo solo sube la capa `application` (KB), no el jar entero.
#
# La JRE se arma con jlink (unos 78 MB frente a los 192 MB de la JRE de
# Temurin) y va sobre debian-slim, que conserva glibc, bash para los
# healthchecks del compose y apt-get.

ARG JDK_IMAGE=eclipse-temurin:25-jdk-jammy
ARG RUNTIME_BASE=debian:13-slim

# java.se entero: quitar modulos no ahorra (mismo tamano que la lista exacta
# de jdeps) y un modulo olvidado falla en ejecucion, no al construir. Los
# jdk.* son los que jdeps no ve: formatos es-CO (localedata), charsets,
# PKCS11, zipfs, DNS de JNDI, y jcmd + agente JMX para diagnosticar.
FROM ${JDK_IMAGE} AS jre
RUN jlink \
        --add-modules java.se,jdk.unsupported,jdk.jfr,jdk.management,jdk.net,jdk.localedata,jdk.charsets,jdk.crypto.cryptoki,jdk.zipfs,jdk.naming.dns,jdk.security.jgss,jdk.xml.dom,jdk.management.agent,jdk.jcmd \
        --strip-debug --no-man-pages --no-header-files --compress=zip-6 \
        --output /jre

FROM maven:3.9-eclipse-temurin-25 AS build
ARG MODULE
WORKDIR /workspace

ENV MAVEN_ARGS="-B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504"

COPY --parents pom.xml */pom.xml common/*/pom.xml ./
RUN test -n "${MODULE}" && test -f "${MODULE}/pom.xml" \
    && mvn -q -pl "${MODULE}" -am dependency:go-offline

# common se copia siempre: lo usan todos menos eurekaserver, y a este solo le
# cuesta invalidar su cache cuando cambia common.
COPY --parents common/*/src ./
COPY ${MODULE}/src ${MODULE}/src
RUN mvn -q -pl "${MODULE}" -am clean package -DskipTests \
    && java -Djarmode=tools -jar "${MODULE}/target/${MODULE}.jar" \
        extract --layers --launcher --destination /extraido

FROM ${RUNTIME_BASE}
ARG MODULE
WORKDIR /app

# XDG_CACHE_HOME: fontconfig (reporting-service) exige una cache escribible
# por el usuario aunque la del sistema este generada; /app es de root.
ENV JAVA_HOME=/opt/java/openjdk \
    LANG=C.UTF-8 \
    XDG_CACHE_HOME=/tmp/.cache
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Base comun: certificados del sistema (TLS de herramientas como curl; Java
# usa su propio cacerts) y tzdata (TZ y /etc/localtime).
# Por servicio, aqui y no como build-arg para que el compose y los workflows
# solo tengan que pasar MODULE:
#   reporting-service: fontconfig y fuentes para JasperReports (PDF).
#   provisioner: curl.
RUN set -eux; \
    case "${MODULE}" in \
        reporting-service) extra="libfontconfig1 fontconfig fonts-dejavu-core" ;; \
        provisioner)       extra="curl" ;; \
        *)                 extra="" ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates tzdata ${extra}; \
    rm -rf /var/lib/apt/lists/*; \
    # Cache de fuentes del sistema generada aqui: el usuario app no puede
    # escribirla en ejecucion y fontconfig avisaria en cada arranque.
    if command -v fc-cache >/dev/null; then fc-cache -f; fi; \
    groupadd --system --gid 10001 app; \
    useradd --system --uid 10001 --gid app --home /app app

COPY --from=jre /jre ${JAVA_HOME}

# De lo que menos cambia a lo que mas: cada capa se reutiliza mientras no
# cambie ella ni ninguna anterior.
COPY --from=build --chown=app:app /extraido/dependencies/ ./
COPY --from=build --chown=app:app /extraido/spring-boot-loader/ ./
COPY --from=build --chown=app:app /extraido/snapshot-dependencies/ ./
COPY --from=build --chown=app:app /extraido/application/ ./

USER app

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75", \
    "-XX:+ExitOnOutOfMemoryError", \
    "-Djava.awt.headless=true", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "org.springframework.boot.loader.launch.JarLauncher"]
