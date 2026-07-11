package com.co.eurekatic.notificationservice.config;

import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Duration;

/**
 * Builds a single {@link CircuitBreakerRegistry} shared by
 * every orchestrator. We use programmatic configuration
 * (no {@code resilience4j-spring-boot4} starter — there is
 * no such artefact on Maven Central).
 *
 * <p>Configuration is bound from {@code notif.circuit-breaker.*}
 * (see {@link CircuitBreakerProperties}). Defaults match
 * the spec's "circuit breaker per provider, sliding window
 * of last 10 calls, open at 50% failures, wait 30 s in
 * OPEN before probing again".
 */
@Configuration
@EnableConfigurationProperties(CircuitBreakerProperties.class)
public class Resilience4jConfig {

    @Bean
    CircuitBreakerRegistry circuitBreakerRegistry(CircuitBreakerProperties props) {
        CircuitBreakerConfig defaults = CircuitBreakerConfig.custom()
                .slidingWindowType(parseSlidingWindow(props.slidingWindowType()))
                .slidingWindowSize(props.slidingWindowSize())
                .minimumNumberOfCalls(props.minimumNumberOfCalls())
                .failureRateThreshold(props.failureRateThreshold())
                .slowCallRateThreshold(props.slowCallRateThreshold())
                .slowCallDurationThreshold(Duration.ofMillis(props.slowCallDurationThresholdMs()))
                .waitDurationInOpenState(Duration.ofMillis(props.waitDurationInOpenStateMs()))
                .permittedNumberOfCallsInHalfOpenState(props.permittedNumberOfCallsInHalfOpenState())
                .automaticTransitionFromOpenToHalfOpenEnabled(true)
                .build();
        return CircuitBreakerRegistry.of(defaults);
    }

    private static CircuitBreakerConfig.SlidingWindowType parseSlidingWindow(String name) {
        return switch (name.toUpperCase()) {
            case "TIME_BASED" -> CircuitBreakerConfig.SlidingWindowType.TIME_BASED;
            default -> CircuitBreakerConfig.SlidingWindowType.COUNT_BASED;
        };
    }
}