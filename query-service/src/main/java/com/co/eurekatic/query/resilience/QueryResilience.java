package com.co.eurekatic.query.resilience;

import io.github.resilience4j.bulkhead.Bulkhead;
import io.github.resilience4j.bulkhead.BulkheadConfig;
import io.github.resilience4j.bulkhead.BulkheadRegistry;
import io.github.resilience4j.ratelimiter.RateLimiter;
import io.github.resilience4j.ratelimiter.RateLimiterConfig;
import io.github.resilience4j.ratelimiter.RateLimiterRegistry;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import com.co.eurekatic.common.security.AuthPrincipal;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Tags;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.time.Duration;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Programmatic Resilience4j wiring for the query path.
 *
 * <p>Two flavors of protection:
 * <ul>
 *   <li><b>Bulkhead</b> — caps concurrent JDBC calls per
 *       dialect. A single slow query on a hot dialect
 *       cannot starve the HikariCP pool for every other
 *       dialect. Configured via
 *       {@code query.resilience.bulkhead.*} properties;
 *       default 8 concurrent (below the Hikari pool) and fail-fast:
 *       there is no queue, an over-cap call is rejected at once.</li>
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
    private final int rateLimitRps;
    private final Duration rateLimitWindow;

    /** One Bulkhead per dialect (postgres / oracle / sqlserver), keyed
     *  lower-case like JdbcTemplateRegistry. Built lazily on first access. */
    private final Map<String, Bulkhead> bulkheads = new ConcurrentHashMap<>();

    /** One RateLimiter per principal (email). Built lazily and evicted
     *  after an idle period, with a hard size cap. */
    private final Cache<String, RateLimiter> rateLimiters;

    /** Rejections, with no per-user tags (bounded cardinality). */
    private final Counter rateLimitRejected;

    public QueryResilience(
            MeterRegistry meters,
            @Value("${query.resilience.bulkhead.max-concurrent:8}") int bulkheadMaxConcurrent,
            @Value("${query.resilience.rate-limit.rps:100}") int rateLimitRps,
            @Value("${query.resilience.rate-limit.window:1s}") Duration rateLimitWindow,
            @Value("${query.resilience.rate-limit.idle-expiry:10m}") Duration rateLimitIdleExpiry,
            @Value("${query.resilience.rate-limit.max-principals:100000}") long rateLimitMaxPrincipals) {
        this.meters = meters;
        this.rateLimiters = Caffeine.newBuilder()
                .expireAfterAccess(rateLimitIdleExpiry)
                .maximumSize(rateLimitMaxPrincipals)
                .build();
        this.rateLimitRejected = meters.counter("query.resilience.rate_limit.rejected");
        this.bulkheadMaxConcurrent = bulkheadMaxConcurrent;
        this.rateLimitRps = rateLimitRps;
        this.rateLimitWindow = rateLimitWindow;
    }

    @PostConstruct
    void publishConfig() {
        log.info("QueryResilience: bulkhead maxConcurrent={} (fail-fast, no queue)",
                bulkheadMaxConcurrent);
        log.info("QueryResilience: rateLimit rps={} window={}",
                rateLimitRps, rateLimitWindow);
    }

    /**
     * Get-or-create a bulkhead for the given dialect. The
     * dialects are discovered lazily (when the first query
     * on each dialect lands) so we don't pre-register
     * unused meters.
     */
    public Bulkhead bulkheadFor(String dialect) {
        return bulkheads.computeIfAbsent(dialect.toLowerCase(Locale.ROOT), this::buildBulkhead);
    }

    private Bulkhead buildBulkhead(String dialect) {
        // SEMAPHORE bulkhead — the right choice for a synchronous MVC
        // controller, since there is no thread handoff.
        //
        // No maxWaitDuration on purpose: QueryService acquires with
        // tryAcquirePermission(), which never waits, so any value set here
        // would be ignored. Waiting is also the wrong behaviour for this
        // service — a caller that has to queue for a JDBC permit is better
        // told 503 + Retry-After immediately than left holding a Tomcat
        // thread hoping one frees up.
        BulkheadConfig config = BulkheadConfig.custom()
                .maxConcurrentCalls(bulkheadMaxConcurrent)
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
    public RateLimiter rateLimiterFor(String principal) {
        return rateLimiters.get(principal, this::buildRateLimiter);
    }

    /**
     * Applies the per-principal cap to the request on this thread, keyed by
     * the JWT subject (email) or, with no principal, by a bucket per
     * client address ({@code X-Client-Ip}, set by the gateway).
     *
     * <p>Lives here rather than in a controller so every read entry point
     * gets the same treatment by construction. It didn't, before: the one
     * endpoint reachable WITHOUT a token ({@code /public/service}) was also
     * the only one that never called a limiter, so the traffic with no
     * identity behind it was the traffic with no cap on it.
     *
     * @throws RequestNotPermitted when the caller is over its limit;
     *         {@code GlobalExceptionHandler} maps it to 429 + Retry-After.
     */
    public void enforceRateLimit() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        String key = (auth != null && auth.getPrincipal() instanceof AuthPrincipal p)
                ? p.email()
                : anonymousKey();
        RateLimiter limiter = rateLimiterFor(key);
        if (!limiter.acquirePermission()) {
            rateLimitRejected.increment();
            // Debug on purpose: the key is an email, and one noisy client
            // would otherwise flood the log at warn.
            log.debug("Rate limit exceeded for principal-hash={}", Integer.toHexString(key.hashCode()));
            throw RequestNotPermitted.createRequestNotPermitted(limiter);
        }
    }

    /** Bucket prefix for callers with no verified identity. */
    static final String ANONYMOUS_PREFIX = "anon:";

    private static String anonymousKey() {
        String ip = null;
        if (RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes sra) {
            ip = sra.getRequest().getHeader("X-Client-Ip");
        }
        return ANONYMOUS_PREFIX + (ip == null || ip.isBlank() ? "unknown" : ip.trim());
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
        return rl;
    }

    private void registerBulkheadMeters(Bulkhead bh, String dialect) {
        Tags tags = Tags.of("dialect", dialect, "kind", "bulkhead");
        meters.gauge("query.resilience.bulkhead.max_concurrent",
                Tags.of("dialect", dialect), bh, b -> b.getBulkheadConfig().getMaxConcurrentCalls());
        meters.gauge("query.resilience.bulkhead.available_concurrent",
                tags, bh, b -> b.getMetrics().getAvailableConcurrentCalls());
    }

    /** Test-only: clear cached instances. */
    public void reset() {
        bulkheads.clear();
        rateLimiters.invalidateAll();
    }
}
