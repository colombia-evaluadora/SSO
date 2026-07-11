package com.co.eurekatic.eureka.observability;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender;
import org.springframework.beans.factory.InitializingBean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires the OpenTelemetry Logback appender for the eurekaserver service.
 *
 * <p>The other 5 services that need OTLP log shipping get this class
 * from the shared {@code com.co.eurekatic:common} library. eurekaserver
 * does not depend on {@code common} (no shared entities, no JPA), and
 * provisioner also keeps its own copy. Behaviour and wiring are
 * intentionally identical across all three copies so they can stay in
 * lockstep — see the corresponding class in
 * {@code com.co.eurekatic.common.observability} for the full rationale.
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