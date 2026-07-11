package com.co.eurekatic.notificationservice.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Typed binding for the {@code notif.circuit-breaker.*}
 * block in {@code application.yml}. The defaults in
 * {@link Resilience4jConfig} match this record's defaults
 * — if the yml block is missing entirely, the registry
 * still works with the same shape.
 */
@ConfigurationProperties(prefix = "notif.circuit-breaker")
public record CircuitBreakerProperties(
        float failureRateThreshold,
        float slowCallRateThreshold,
        long slowCallDurationThresholdMs,
        long waitDurationInOpenStateMs,
        int permittedNumberOfCallsInHalfOpenState,
        String slidingWindowType,
        int slidingWindowSize,
        int minimumNumberOfCalls
) {

    public CircuitBreakerProperties {
        if (slidingWindowType == null) slidingWindowType = "COUNT_BASED";
        if (failureRateThreshold == 0) failureRateThreshold = 50.0f;
        if (slowCallRateThreshold == 0) slowCallRateThreshold = 100.0f;
        if (slowCallDurationThresholdMs == 0) slowCallDurationThresholdMs = 5_000L;
        if (waitDurationInOpenStateMs == 0) waitDurationInOpenStateMs = 30_000L;
        if (permittedNumberOfCallsInHalfOpenState == 0) permittedNumberOfCallsInHalfOpenState = 3;
        if (slidingWindowSize == 0) slidingWindowSize = 10;
        if (minimumNumberOfCalls == 0) minimumNumberOfCalls = 5;
    }
}