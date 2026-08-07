package com.co.eurekatic.query.observability;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Tags;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * V31 — Micrometer instrumentation for the path-template + catalog
 * surface. Single bean injected anywhere we need to record
 * counters; the {@link MeterRegistry} is auto-wired by Spring Boot
 * Actuator (the {@code OTLP metrics export} config in
 * {@code application.yml} ships the metrics to Alloy →
 * Mimir for Grafana dashboards).
 *
 * <p>Cardinality discipline: every counter carries a small,
 * bounded set of tags. We never tag by uuid / microservice id
 * / path template — those are unbounded and would blow up the
 * TSDB. Status tags use a fixed enum ({@code success},
 * {@code failure}); mode tags use the
 * {@link com.co.eurekatic.common.entity.ExecutionMode} names.
 *
 * <p>The map-of-counters pattern keeps registration lazy — we
 * don't pre-register every (tag × value) combination at boot;
 * the first call with a new tag value creates the meter and
 * caches it.
 */
@Component
public class QueryMetrics {

    public enum Outcome { SUCCESS, FAILURE }
    public enum Match { HIT, MISS }

    private final MeterRegistry registry;
    private final ConcurrentMap<String, Counter> counters = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, Timer> timers = new ConcurrentHashMap<>();

    public QueryMetrics(MeterRegistry registry) {
        this.registry = registry;
    }

    /* ====================== path registry ====================== */

    /** Refresh tick result. Tagged by outcome only. */
    public void recordRegistryRefresh(Outcome outcome, int templatesLoaded) {
        counter("query.path_registry.refresh",
                Tags.of("outcome", outcome.name().toLowerCase()))
                .increment();
        if (outcome == Outcome.SUCCESS) {
            counter("query.path_registry.templates_loaded")
                    .increment(templatesLoaded);
        }
    }

    /** Path-dispatch match. Tagged by hit/miss only. */
    public void recordRegistryMatch(Match result) {
        counter("query.path_registry.match",
                Tags.of("result", result.name().toLowerCase()))
                .increment();
    }

    /** Current registry size — polled by the gauge. */
    public void registerRegistrySizeGauge(java.util.function.Supplier<Number> supplier) {
        registry.gauge("query.path_registry.size", supplier);
    }

    /* ====================== catalog client ====================== */

    /** Catalog call result. Tagged by endpoint + outcome. */
    public void recordCatalogCall(String endpoint, Outcome outcome, long nanos) {
        counter("query.catalog.call",
                Tags.of("endpoint", endpoint,
                        "outcome", outcome.name().toLowerCase()))
                .increment();
        timer("query.catalog.latency",
                Tags.of("endpoint", endpoint,
                        "outcome", outcome.name().toLowerCase()))
                .record(java.time.Duration.ofNanos(nanos));
    }

    /* ====================== query execution ====================== */

    /**
     * Query execution result. Tagged by mode (SELECT / PROCEDURE
     * / FUNCTION) + outcome. Lets ops dashboards split latency
     * by execution mode — procedures typically take longer
     * than SELECTs.
     */
    public void recordExecution(String mode, Outcome outcome, long nanos) {
        counter("query.execution",
                Tags.of("mode", mode,
                        "outcome", outcome.name().toLowerCase()))
                .increment();
        timer("query.execution.latency",
                Tags.of("mode", mode))
                .record(java.time.Duration.ofNanos(nanos));
    }

    /* ====================== helpers ====================== */

    private Counter counter(String name, Tags tags) {
        String key = name + "|" + tags;
        return counters.computeIfAbsent(key, k ->
                Counter.builder(name).tags(tags).register(registry));
    }

    private Counter counter(String name) {
        return counter(name, Tags.empty());
    }

    private Timer timer(String name, Tags tags) {
        String key = name + "|" + tags;
        return timers.computeIfAbsent(key, k ->
                Timer.builder(name).tags(tags).register(registry));
    }
}
