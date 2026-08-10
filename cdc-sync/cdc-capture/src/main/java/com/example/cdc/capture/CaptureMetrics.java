package com.example.cdc.capture;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Component;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

@Component
public class CaptureMetrics {

    private final MeterRegistry registry;
    private final ConcurrentMap<String, Counter> counters = new ConcurrentHashMap<>();

    public CaptureMetrics(MeterRegistry registry) {
        this.registry = registry;
    }

    public void incrementPublished(String tabla, String op) {
        String key = tabla + ":" + op;
        counters.computeIfAbsent(key, k -> Counter.builder("cdc.events.published")
                .tag("tabla", tabla)
                .tag("op", op)
                .register(registry))
                .increment();
    }

    /**
     * Counts Debezium snapshot rows (op="r") that AmqpPublisher filtered out before
     * publishing. Visible as {@code cdc.events.snapshot_skipped{tabla=...}} so an
     * operator can tell how many bootstrap rows would have leaked into
     * auditoria.audit_log / Oracle MERGEs had the guard not been in place.
     */
    public void incrementSnapshotSkipped(String tabla) {
        String key = "snapshot:" + tabla;
        counters.computeIfAbsent(key, k -> Counter.builder("cdc.events.snapshot_skipped")
                .tag("tabla", tabla)
                .register(registry))
                .increment();
    }
}
