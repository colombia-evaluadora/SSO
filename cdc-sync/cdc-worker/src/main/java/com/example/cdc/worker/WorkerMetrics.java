package com.example.cdc.worker;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.TimeUnit;

@Component
public class WorkerMetrics {

    private final MeterRegistry registry;
    private final ConcurrentMap<String, Counter> counters = new ConcurrentHashMap<>();

    public WorkerMetrics(MeterRegistry registry) {
        this.registry = registry;
    }

    public void incrementConsumed(String tabla, String op, String estado) {
        String key = tabla + ":" + op + ":" + estado;
        counters.computeIfAbsent(key, k -> Counter.builder("cdc.events.consumed")
                .tag("tabla", tabla)
                .tag("op", op)
                .tag("estado", estado)
                .register(registry))
                .increment();
    }

    public void incrementDlq() {
        registry.counter("cdc.events.dlq").increment();
    }

    public void recordOracleMerge(long millis) {
        registry.timer("cdc.oracle.merge.ms").record(millis, TimeUnit.MILLISECONDS);
    }

    public void recordClickHouseInsert(long millis) {
        registry.timer("cdc.clickhouse.insert.ms").record(millis, TimeUnit.MILLISECONDS);
    }

    public void setLagSeconds(long seconds) {
        registry.gauge("cdc.lag.seconds", seconds);
    }
}