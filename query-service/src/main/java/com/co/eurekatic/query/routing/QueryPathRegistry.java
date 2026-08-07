package com.co.eurekatic.query.routing;

import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.observability.QueryMetrics;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.util.AntPathMatcher;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * V27 — in-memory {@code Map<pathTemplate, uuid>} the
 * {@code QueryPathController} consults to resolve an
 * incoming request's path to a catalog uuid. Loaded from
 * sso-admin's catalog at startup and refreshed periodically
 * (default 60s; configurable via
 * {@code query.path-registry.refresh-ms}).
 *
 * <p>Concurrency: reads happen on every request, writes
 * happen on a single scheduled thread. We swap the entire
 * map atomically via {@link AtomicReference} — readers see
 * either the old or the new table, never a partial
 * overwrite. The pattern is the standard "copy on write"
 * idiom for hot-read / rare-write maps.
 *
 * <p>This is per-instance state: each query-service
 * container maintains its own registry. The catalog is the
 * shared source of truth; refresh keeps every instance
 * eventually consistent. {@code @Scheduled} runs on a
 * single-thread scheduler per JVM, so there's no race
 * between two refresh ticks in the same process.
 */
@Component
public class QueryPathRegistry {

    private static final Logger log = LoggerFactory.getLogger(QueryPathRegistry.class);

    private final CatalogClient catalog;
    private final QueryMetrics metrics;
    private final AntPathMatcher matcher = new AntPathMatcher();
    private final AtomicReference<Map<String, String>> tableRef =
            new AtomicReference<>(Map.of());
    private final String instanceName;
    /**
     * V32 — resolved at boot via {@code /internal/whoami}.
     * Null when the catalog has no row for our instance
     * name (registry stays scoped to "global" — every
     * path-template query, including rows owned by other
     * instances). Path uniqueness is per-microserviceId,
     * so two instances answering for the same template is
     * impossible.
     */
    private final AtomicLong myMicroserviceId = new AtomicLong(-1L);

    public QueryPathRegistry(CatalogClient catalog,
                             QueryMetrics metrics,
                             @Value("${query.instance.name:#{null}}") String instanceName) {
        this.catalog = catalog;
        this.metrics = metrics;
        this.instanceName = instanceName;
    }

    /**
     * Register the size gauge once at startup so dashboards
     * have a continuous view of registry population. The
     * gauge reads {@code tableRef.get()} lazily on each
     * scrape — cheap and always current.
     */
    @PostConstruct
    void registerSizeGauge() {
        metrics.registerRegistrySizeGauge(() -> tableRef.get().size());
    }

    /**
     * V32 — resolve our own {@code microserviceId} from the
     * catalog at boot. We need the instance name to be set
     * (the provisioner passes {@code QUERY_INSTANCE_NAME}
     * when it creates the container). When unset or the
     * catalog has no matching row, we fall back to
     * "global" (microserviceId=-1 → the periodic refresh
     * passes {@code null} to fetchPathTemplates).
     *
     * <p>Failure mode is graceful: if sso-admin is
     * unreachable at boot time, the registry keeps
     * working with the global scope and the periodic
     * refresh can discover our id later (the
     * {@code myMicroserviceId} value is updated each tick).
     */
    private void resolveMyMicroserviceId() {
        if (instanceName == null || instanceName.isBlank()) {
            log.info("QueryPathRegistry: no query.instance.name; staying global");
            return;
        }
        try {
            Map<String, Object> who = catalog.whoami(instanceName);
            Object idObj = who.get("microserviceId");
            if (idObj instanceof Number n) {
                long id = n.longValue();
                myMicroserviceId.set(id);
                log.info("QueryPathRegistry: resolved microserviceId={} for instanceName={}",
                        id, instanceName);
            } else {
                log.info("QueryPathRegistry: no microservice row for instanceName={}; "
                        + "staying global", instanceName);
            }
        } catch (Exception e) {
            log.warn("QueryPathRegistry: whoami failed; staying global: {}",
                    e.getMessage());
        }
    }

    /**
     * Register the size gauge once at startup so dashboards
     * have a continuous view of registry population. The
     * gauge reads {@code tableRef.get()} lazily on each
     * scrape — cheap and always current.
     */
    @PostConstruct
    void registerSizeGauge() {
        metrics.registerRegistrySizeGauge(() -> tableRef.get().size());
    }

    /**
     * Initial load — fires at startup so the registry is
     * warm before the first request arrives. A failure here
     * logs at WARN; the registry stays empty and the
     * controller returns 404 for every path request until
     * the periodic refresh succeeds. Better to start
     * degraded than to refuse to start.
     */
    @Scheduled(fixedDelayString = "${query.path-registry.refresh-ms:60000}",
               initialDelay = 0)
    public void refresh() {
        // V32 — re-resolve our microserviceId on every
        // tick. Cheap (one HTTP roundtrip to /internal/whoami)
        // and means a fresh deploy of sso-admin's catalog
        // picks up the assignment without a query-service
        // restart.
        resolveMyMicroserviceId();
        try {
            Map<String, String> next = new LinkedHashMap<>();
            // V30+V32 — call the dedicated internal endpoint
            // /internal/pathTemplates (server-side filtered to
            // rows with a non-null pathTemplate). Auth is the
            // shared X-Internal-Token header. We pass our
            // resolved microserviceId so the registry only
            // contains templates WE should answer for; rows
            // for other instances are excluded server-side.
            Long id = myMicroserviceId.get() < 0 ? null : myMicroserviceId.get();
            List<QueryDefinition> templates = catalog.fetchPathTemplates(id);
            for (QueryDefinition q : templates) {
                if (q.pathTemplate() != null && !q.pathTemplate().isBlank()) {
                    next.put(q.pathTemplate(), q.uuid());
                }
            }
            tableRef.set(Map.copyOf(next));
            log.info("QueryPathRegistry: {} path templates loaded for instance={} (microserviceId={})",
                    next.size(), instanceName, id);
            metrics.recordRegistryRefresh(QueryMetrics.Outcome.SUCCESS, next.size());
        } catch (Exception e) {
            log.warn("QueryPathRegistry refresh failed (keeping previous {} entries): {}",
                    tableRef.get().size(), e.getMessage());
            metrics.recordRegistryRefresh(QueryMetrics.Outcome.FAILURE, 0);
        }
    }

    /**
     * Match an incoming path against the registered templates.
     * Returns the uuid + extracted path variables on the first
     * match (templates are walked in iteration order, so the
     * catalog author can rely on declaration order — more
     * specific templates declared first).
     */
    public Optional<Match> match(String path) {
        if (path == null || path.isEmpty()) {
            return Optional.empty();
        }
        // The gateway forwards with the prefix already
        // stripped, so the path arrives as
        // "/<pathTemplate-suffix>" (e.g. "/establecimiento/42").
        // Strip a trailing slash to keep the matcher happy
        // with templates that don't have one.
        String normalized = path.endsWith("/") && path.length() > 1
                ? path.substring(0, path.length() - 1)
                : path;
        Map<String, String> snapshot = tableRef.get();
        for (Map.Entry<String, String> e : snapshot.entrySet()) {
            if (matcher.match(e.getKey(), normalized)) {
                Map<String, String> vars = matcher
                        .extractUriTemplateVariables(e.getKey(), normalized);
                metrics.recordRegistryMatch(QueryMetrics.Match.HIT);
                return Optional.of(new Match(e.getValue(), vars));
            }
        }
        metrics.recordRegistryMatch(QueryMetrics.Match.MISS);
        return Optional.empty();
    }

    public int size() {
        return tableRef.get().size();
    }

    public record Match(String uuid, Map<String, String> pathVars) {}

    /**
     * V33 — immediate refresh trigger exposed via the
     * {@code POST /internal/invalidatePathRegistry} endpoint.
     * Called by sso-admin after a catalog mutation
     * (create/update/delete) so the path-registry picks up
     * the change without waiting for the periodic 60s tick.
     * Idempotent: a no-op when nothing changed.
     *
     * <p>Returns the new registry size so the caller can log
     * / verify the refresh actually loaded something.
     */
    public int invalidate() {
        refresh();
        return size();
    }
}
