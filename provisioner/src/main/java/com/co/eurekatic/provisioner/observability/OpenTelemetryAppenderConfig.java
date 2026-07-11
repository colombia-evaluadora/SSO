package com.co.eurekatic.provisioner.observability;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender;
import org.springframework.beans.factory.InitializingBean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires the OpenTelemetry Logback appender for the provisioner service.
 *
 * <p>The other 5 services get this class from the shared
 * {@code com.co.eurekatic:common} library. The provisioner does not
 * depend on {@code common} (it has no JPA / shared entities), so the
 * configuration is duplicated here. The behaviour and the wiring are
 * intentionally identical to the version in {@code common} so the
 * two copies can be kept in lockstep — see the corresponding class
 * in {@code com.co.eurekatic.common.observability} for the rationale.
 */
@Configuration(proxyBeanMethods = false)
public class OpenTelemetryAppenderConfig implements InitializingBean {

    private final OpenTelemetry openTelemetry;

    public OpenTelemetryAppenderConfig(OpenTelemetry openTelemetry) {
        this.openTelemetry = openTelemetry;
    }

    @Override
    public void afterPropertiesSet() {
        OpenTelemetryAppender.install(openTelemetry);
    }
}
