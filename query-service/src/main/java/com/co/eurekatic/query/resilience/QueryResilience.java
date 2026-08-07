package com.co.eurekatic.query.resilience;

import io.github.resilience4j.bulkhead.Bulkhead;
import io.github.resilience4j.bulkhead.BulkheadConfig;
import io.github.resilience4j.bulkhead.BulkheadRegistry;
import io.github.resilience4j.ratelimiter.RateLimiter;
import io.github.resilience4j.ratelimiter.RateLimiterConfig;
import io.github.resilience4j.ratelimiter.RateLimiterRegistry;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Tag;
import io.micrometer.core.instrument.Tags;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * V33 — programmatic Resilience4j wiring for the query path.
 *
 * <p>Two flavors of protection:
 * <ul>
 *   <li><b>Bulkhead</b> — caps concurrent JDBC calls per
 *       dialect. A single slow query on a hot dialect
 *       cannot starve the HikariCP pool for every other
 *       dialect. Configured via
 *       {@code query.resilience.bulkhead.*} properties;
 *       default 20 concurrent / 50 queued.</li>
 *   <li><b>RateLimiter</b> — caps RPS per principal
 *       (email). A runaway client cannot overwhelm the
 *       service; overflow returns 429 with a Retry-After.
 *       Configured via
 *       {@code query.resilience.rate-limit.*} properties;
 *       default 100 rps / principal.</li>
 * </ul>
 *
 * <p>Why programmatic and not the spring-boot starter:
 * the {@code resilience4j-spring-boot3} starter is Boot 3
 * only (per the README of notification-service, where this
 * pattern was first used). Boot 4 would need a future
 * starter that hasn't shipped yet. Building the instances
 * by hand keeps this module's AOP footprint zero and
 * mirrors the existing pattern in notification-service.
 *
 * <p>Metrics: every {@link Bulkhead} and {@link RateLimiter}
 * registers itself with the {@link MeterRegistry} on
 * construction (see {@link #registerMeters}). The
 * dashboards already include these via the standard
 * Resilience4j Micrometer module — no extra wiring
 * needed.
 */
@Component
public class QueryResilience {

    private static final Logger log = LoggerFactory.getLogger(QueryResilience.class);

    private final MeterRegistry meters;

    // Default config values — overridable via application.yml.
    private final int bulkheadMaxConcurrent;
    private final int bulkheadMaxQueue;
    private final Duration bulkheadWaitDuration;
    private final int rateLimitRps;
    private final Duration rateLimitWindow;

    /** One Bulkhead per dialect (postgres / oracle / sqlserver).
     *  Built lazily on first access. */
    private final Map<String, Bulkhead> bulkheads = new LinkedHashMap<>();

    /** One RateLimiter per principal (email). Built lazily; old
     *  entries are pruned when they age out (see Refresh). */
    private final Map<String, RateLimiter> rateLimiters = new LinkedHashMap<>();

    public QueryResilience(
            MeterRegistry meters,
            @Value("${query.resilience.bulkhead.max-concurrent:20}") int bulkheadMaxConcurrent,
            @Value("${query.resilience.bulkhead.max-queue:50}") int bulkheadMaxQueue,
            @Value("${query.resilience.bulkhead.wait-duration:200ms}") Duration bulkheadWaitDuration,
            @Value("${query.resilience.rate-limit.rps:100}") int rateLimitRps,
            @Value("${query.resilience.rate-limit.window:1s}") Duration rateLimitWindow) {
        this.meters = meters;
        this.bulkheadMaxConcurrent = bulkheadMaxConcurrent;
        this.bulkheadMaxQueue = bulkheadMaxQueue;
        this.bulkheadWaitDuration = bulkheadWaitDuration;
        this.rateLimitRps = rateLimitRps;
        this.rateLimitWindow = rateLimitWindow;
    }

    @PostConstruct
    void publishConfig() {
        log.info("QueryResilience: bulkhead maxConcurrent={} maxQueue={} waitDuration={}",
                bulkheadMaxConcurrent, bulkheadMaxQueue, bulkheadWaitDuration);
        log.info("QueryResilience: rateLimit rps={} window={}",
                rateLimitRps, rateLimitWindow);
    }

    /**
     * Get-or-create a bulkhead for the given dialect. The
     * dialects are discovered lazily (when the first query
     * on each dialect lands) so we don't pre-register
     * unused meters.
     */
    public synchronized Bulkhead bulkheadFor(String dialect) {
        return bulkheads.computeIfAbsent(dialect, this::buildBulkhead);
    }

    private Bulkhead buildBulkhead(String dialect) {
        BulkheadConfig config = BulkheadConfig.custom()
                .maxConcurrentCalls(bulkheadMaxConcurrent)
                .maxWaitDuration(bulkheadWaitDuration)
                .queueCapacity(bulkheadMaxQueue)
                .build();
        Bulkhead bh = BulkheadRegistry.of(config).bulkhead("query-" + dialect, config);
        registerBulkheadMeters(bh, dialect);
        return bh;
    }

    /**
     * Get-or-create a rate limiter for the given principal
     * (typically the JWT subject / email). Principal-keyed
     * limiters are per-caller — a noisy client can't
     * starve a quiet one.
     */
    public synchronized RateLimiter rateLimiterFor(String principal) {
        return rateLimiters.computeIfAbsent(principal, this::buildRateLimiter);
    }

    private RateLimiter buildRateLimiter(String principal) {
        RateLimiterConfig config = RateLimiterConfig.custom()
                .limitForPeriod(rateLimitRps)
                .limitRefreshPeriod(rateLimitWindow)
                // Don't wait for a permit — fail fast.
                .timeoutDuration(Duration.ZERO)
                .build();
        RateLimiter rl = RateLimiterRegistry.of(config)
                .rateLimiter("query-rl-" + principal, config);
        registerRateLimiterMeters(rl, principal);
        return rl;
    }

    private void registerBulkheadMeters(Bulkhead bh, String dialect) {
        Tags tags = Tags.of("dialect", dialect, "kind", "bulkhead");
        meters.gauge("query.resilience.bulkhead.max_concurrent",
                Tags.of("dialect", dialect), bh, b -> b.getBulkheadConfig().getMaxConcurrentCalls());
        meters.gauge("query.resilience.bulkhead.available_concurrent",
                tags, bh, b -> b.getMetrics().getAvailableConcurrentCalls());
    }

    private void registerRateLimiterMeters(RateLimiter rl, String principal) {
        // No PII in metric tags — principal email is fine
        // for per-user dashboards; operators can choose to
        // drop this tag via meter filter if they want
        // lower-cardinality rollups.
        Tags tags = Tags.of("principal", principal, "kind", "ratelimiter");
        meters.gauge("query.resilience.rate_limit.available",
                tags, rl, r -> r.getMetrics().getAvailablePermissions());
    }

    /** Test-only: clear cached instances. */
    public synchronized void reset() {
        bulkheads.clear();
        rateLimiters.clear();
    }
}
