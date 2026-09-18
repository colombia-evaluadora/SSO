package com.co.eurekatic.common.observability;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.InitializingBean;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.context.annotation.Configuration;

/**
 * Wires the OpenTelemetry Logback appender so every log line is shipped as
 * an OTLP log record to the Grafana Alloy collector.
 *
 * <p>Spring Boot 4's {@code spring-boot-starter-opentelemetry} exports metrics
 * and traces out of the box, but the official Spring blog post
 * (<a href="https://spring.io/blog/2025/11/18/opentelemetry-with-spring-boot">2025-11-18</a>)
 * is explicit: the starter <em>does not</em> install a Logback or Log4j2 appender
 * by default. The appender artifact
 * ({@code io.opentelemetry.instrumentation:opentelemetry-logback-appender-1.0})
 * is a separate dependency that must be added explicitly, and the static
 * {@link OpenTelemetryAppender#install(OpenTelemetry)} call must run during
 * context startup so the appender knows which {@link OpenTelemetry} instance
 * to forward events to.
 *
 * <p>{@code @ConditionalOnClass} prevents this from blowing up services that
 * include this library transitively but do not add the appender dependency
 * (e.g. the Eureka server has no observability requirements).
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnClass(OpenTelemetryAppender.class)
public class OpenTelemetryAppenderConfig implements InitializingBean {

    private static final Logger log = LoggerFactory.getLogger(OpenTelemetryAppenderConfig.class);

    private final ObjectProvider<OpenTelemetry> openTelemetry;
    private final boolean logExportEnabled;

    // Leemos `management.logging.export.otlp.enabled` (que el compose
    // deriva de SSO_TELEMETRY_ENABLED, y que cada application.yml deja
    // en false si la env var no viene) en vez de inventar un nombre
    // propio: es LA propiedad que gobierna el exporter OTLP de logs en
    // Spring Boot, así que el appender y el exporter se encienden y
    // apagan juntos. Antes se gateaba por el flag de TRAZAS, que no es
    // el que decide si los logs viajan a Alloy.
    public OpenTelemetryAppenderConfig(
            ObjectProvider<OpenTelemetry> openTelemetry,
            @Value("${management.logging.export.otlp.enabled:true}") boolean logExportEnabled) {
        this.openTelemetry = openTelemetry;
        this.logExportEnabled = logExportEnabled;
    }

    @Override
    public void afterPropertiesSet() {
        // El appender OTEL está declarado siempre en logback-spring.xml
        // (Logback no puede condicionarlo sin Janino) y, mientras nadie
        // llame a install(), va acumulando eventos en memoria a la espera
        // de un OpenTelemetry que en este caso nunca llegaría. Con la
        // telemetría apagada lo apuntamos explícitamente al no-op: vacía
        // ese buffer, no retiene nada más y no hay exporter detrás, así
        // que ningún log intenta salir hacia Alloy.
        if (!logExportEnabled) {
            OpenTelemetryAppender.install(OpenTelemetry.noop());
            log.info("Export OTLP de logs deshabilitado "
                    + "(management.logging.export.otlp.enabled=false); "
                    + "el appender OTEL queda en no-op y los logs salen sólo por CONSOLE.");
            return;
        }
        // El bean OpenTelemetry sólo existe si el servicio incluye
        // el starter OTel Y un exporter está habilitado. Con
        // ObjectProvider evitamos que la ausencia del bean bloquee
        // el startup (lo que pasaba antes del V35): si no hay, el
        // appender simplemente no se registra y los logs salen por
        // CONSOLE. Es el mismo comportamiento que un servicio que
        // nunca tuvo observabilidad.
        OpenTelemetry ot = openTelemetry.getIfAvailable();
        if (ot == null) {
            OpenTelemetryAppender.install(OpenTelemetry.noop());
            log.warn("OpenTelemetry bean no disponible; el appender OTEL "
                    + "queda en no-op y los logs salen sólo por CONSOLE.");
            return;
        }
        // Idempotent at runtime per JVM (the static install is a
        // single-slot assignment), but Spring's lifecycle guarantees
        // this fires exactly once per application context.
        OpenTelemetryAppender.install(ot);
    }
}
