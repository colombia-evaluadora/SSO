package com.co.eurekatic.provisioner.observability;

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
 * Wires the OpenTelemetry Logback appender for the provisioner service.
 *
 * <p>The other services that need OTLP log shipping get this class
 * from the shared {@code com.co.eurekatic:common} library. provisioner
 * does not depend on {@code common} (no shared entities, no JPA), so
 * the configuration is duplicated here. Behaviour and wiring are
 * intentionally identical across the three copies (common, eurekaserver,
 * provisioner) so they can stay in lockstep — see the corresponding
 * class in {@code com.co.eurekatic.common.observability} for the
 * full rationale.
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
