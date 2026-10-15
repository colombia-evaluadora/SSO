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

ARG RUNTIME_BASE=eclipse-temurin:25-jre-jammy

FROM maven:3.9-eclipse-temurin-25 AS build
ARG MODULE
WORKDIR /workspace

ENV MAVEN_ARGS="-B -ntp -Dmaven.wagon.http.retryHandler.count=5 -Daether.connector.http.retryHandler.count=5 -Daether.connector.http.retryHandler.serviceUnavailable=429,502,503,504"

COPY --parents pom.xml */pom.xml ./
RUN test -n "${MODULE}" && test -f "${MODULE}/pom.xml" \
    && mvn -q -pl "${MODULE}" -am dependency:go-offline

# common se copia siempre: lo usan todos menos eurekaserver, y a este solo le
# cuesta invalidar su cache cuando cambia common.
COPY common/src common/src
COPY ${MODULE}/src ${MODULE}/src
RUN mvn -q -pl "${MODULE}" -am clean package -DskipTests \
    && java -Djarmode=tools -jar "${MODULE}/target/${MODULE}.jar" \
        extract --layers --launcher --destination /extraido

FROM ${RUNTIME_BASE}
ARG MODULE
WORKDIR /app

# Paquetes del sistema por servicio, aqui y no como build-arg para que el
# compose y los workflows solo tengan que pasar MODULE.
#   reporting-service: fuentes y freetype para JasperReports (PDF).
#   provisioner: curl.
RUN set -eux; \
    case "${MODULE}" in \
        reporting-service) paquetes="libfreetype6 libfontconfig1 fontconfig fonts-dejavu-core" ;; \
        provisioner)       paquetes="curl" ;; \
        *)                 paquetes="" ;; \
    esac; \
    if [ -n "${paquetes}" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends ${paquetes}; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    groupadd --system --gid 10001 app; \
    useradd --system --uid 10001 --gid app --home /app app

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
