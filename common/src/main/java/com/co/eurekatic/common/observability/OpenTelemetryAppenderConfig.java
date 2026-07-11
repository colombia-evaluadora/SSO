package com.co.eurekatic.common.observability;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender;
import org.springframework.beans.factory.InitializingBean;
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

    private final OpenTelemetry openTelemetry;

    public OpenTelemetryAppenderConfig(OpenTelemetry openTelemetry) {
        this.openTelemetry = openTelemetry;
    }

    @Override
    public void afterPropertiesSet() {
        // Idempotent at runtime per JVM (the static install is a
        // single-slot assignment), but Spring's lifecycle guarantees
        // this fires exactly once per application context.
        OpenTelemetryAppender.install(openTelemetry);
    }
}
