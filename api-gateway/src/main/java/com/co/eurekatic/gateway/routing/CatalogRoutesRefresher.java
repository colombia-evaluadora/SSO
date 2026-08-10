package com.co.eurekatic.gateway.routing;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Tags;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.event.RefreshRoutesEvent;
import org.springframework.cloud.gateway.filter.FilterDefinition;
import org.springframework.cloud.gateway.handler.predicate.PredicateDefinition;
import org.springframework.cloud.gateway.route.RouteDefinition;
import org.springframework.cloud.gateway.route.RouteDefinitionWriter;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.net.URI;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * V27 — polls sso-admin's {@code /internal/gateway/routes}
 * endpoint and publishes a {@link RefreshRoutesEvent} so the
 * Spring Cloud Gateway {@code RouteDefinitionRepository}
 * rebuilds its routing table with the catalog-driven routes.
 *
 * <p>The static routes in {@code application.yml} and the
 * Eureka {@code discovery.locator} routes coexist with these
 * dynamic ones — Spring Cloud Gateway merges all three
 * sources. Catalog-driven routes win when ids collide because
 * their ids are deterministic ({@code catalog-<serviceId>});
 * the YAML routes have their own ids.
 *
 * <p>Why a poller rather than a push (SSE / websocket /
 * RabbitMQ): a poller is stateless from the sso-admin side —
 * the catalog doesn't need to know who is listening.
 * Failure mode is graceful: if sso-admin is unreachable, the
 * previous routes stay in effect; on the next successful
 * refresh the table is rebuilt.
 *
 * <p>Failure isolation: a refresh that fails (HTTP error,
 * timeout, parse error) logs at WARN and keeps the previous
 * routes. We never publish a partial / empty table — the
 * gateway would 404 every request during a sso-admin outage,
 * which is the opposite of what we want for an internal
 * poll-and-update loop.
 *
 * <p><b>Authentication</b>: sso-admin's {@code /internal/**}
 * surface is gated by {@code InternalTokenFilter}, which
 * requires a constant-time-matched {@code X-Internal-Token}
 * header. The token is configured via {@code gateway.internal-token}
 * (env: {@code GATEWAY_INTERNAL_TOKEN}); it MUST match
 * sso-admin's {@code sso.internal.token} ({@code SSO_INTERNAL_TOKEN}).
 * When the token is missing/blank the poller skips the
 * header and sso-admin 401s every poll — visible in the
 * gateway's startup log as a one-shot WARN so the operator
 * can tell at a glance that dynamic routing is offline.
 * Empty-by-default preserves back-compat with deployments
 * that only rely on the static {@code /api/qs/**} path.
 */
@Component
public class CatalogRoutesRefresher {

    private static final Logger log = LoggerFactory.getLogger(CatalogRoutesRefresher.class);

    /** Header name; mirrors {@code InternalTokenFilter.HEADER} in sso-admin. */
    static final String INTERNAL_TOKEN_HEADER = "X-Internal-Token";

    /**
     * Rows with this {@code kind} are the ones we own. REST
     * rows (sso-admin, auth-center) are deliberately skipped —
     * see {@link #refresh()}.
     */
    static final String QUERY_KIND = "QUERY";

    private final WebClient client;
    private final ApplicationEventPublisher publisher;
    private final RouteDefinitionWriter routeWriter;
    private final MeterRegistry meters;
    private final String internalToken;
    private final AtomicInteger lastPublishedCount = new AtomicInteger(0);
    /**
     * Ids we wrote on the previous successful poll, so a row
     * deleted from the catalog gets its route deleted too
     * instead of lingering until the next gateway restart.
     */
    private final Set<String> publishedIds = ConcurrentHashMap.newKeySet();

    public CatalogRoutesRefresher(
            ApplicationEventPublisher publisher,
            RouteDefinitionWriter routeWriter,
            MeterRegistry meters,
            @Value("${gateway.catalog-url:http://sso-admin:8080}") String catalogBaseUrl,
            @Value("${gateway.internal-token:}") String internalToken) {
        // V27 fix — Spring Boot 4's spring-cloud-starter-gateway-
        // server-webflux does NOT auto-register a WebClient.Builder
        // bean (unlike Boot 3's spring-cloud-starter-gateway which
        // did). The previous constructor took WebClient.Builder
        // as a parameter and failed at startup with
        // "No qualifying bean of type WebClient.Builder available".
        //
        // We now build a WebClient directly with the codecs and
        // base URL baked in. WebClient.create() returns a
        // preconfigured instance backed by the Reactor Netty
        // client that's already on the classpath. The exchange
        // functions (codecs, timeouts) match what the autoconfig
        // would have produced; we just skip the autoconfig.
        this.client = WebClient.builder()
                .baseUrl(catalogBaseUrl)
                .build();
        this.publisher = publisher;
        this.routeWriter = routeWriter;
        this.meters = meters;
        this.internalToken = internalToken;
        log.info("CatalogRoutesRefresher: baseUrl={}", catalogBaseUrl);
        if (internalToken == null || internalToken.isBlank()) {
            // One-shot WARN at startup so the operator
            // notices dynamic routing is offline. The
            // existing per-poll WARN (in the catch block
            // below) would also catch it, but a startup
            // line is easier to grep for in
            // `docker logs … | grep 'CatalogRoutesRefresher'`.
            log.warn("CatalogRoutesRefresher: gateway.internal-token is not "
                    + "configured; sso-admin will 401 every /internal/gateway/routes "
                    + "poll and dynamic catalog routing will stay empty. "
                    + "Set GATEWAY_INTERNAL_TOKEN to the same value as "
                    + "sso-admin's SSO_INTERNAL_TOKEN.");
        }
    }

    /**
     * Polls every {@code gateway.catalog-refresh-ms} ms (default 30s).
     * The initial 5s delay lets the rest of the context (Eureka,
     * the static routes) come up first so a misconfigured startup
     * doesn't permanently disable catalog routes.
     */
    @Scheduled(fixedDelayString = "${gateway.catalog-refresh-ms:30000}",
               initialDelay = 5_000)
    public void refresh() {
        try {
            // Build the request inline so the X-Internal-Token
            // header is conditional on configuration. Doing it
            // once at construction time would be cheaper but
            // would couple the WebClient to a static header
            // value — if the operator rotates the token at
            // runtime (via Spring's @RefreshScope), the
            // WebClient would keep sending the old one. The
            // header is cheap to recompute per poll.
            var request = client.get()
                    .uri("/internal/gateway/routes");
            if (internalToken != null && !internalToken.isBlank()) {
                request = request.header(INTERNAL_TOKEN_HEADER, internalToken);
            }
            List<GatewayRouteDto> routes = request
                    .retrieve()
                    .bodyToMono(new ParameterizedTypeReference<List<GatewayRouteDto>>() {})
                    .block();
            if (routes == null || routes.isEmpty()) {
                log.debug("Catalog returned no routes; keeping previous {} routes",
                        lastPublishedCount.get());
                return;
            }
            // Build every RouteDefinition in one batch, write
            // them to the repository, THEN publish a single
            // RefreshRoutesEvent — SCG's CachingRouteLocator
            // listens for the event and reloads from all
            // sources (DiscoveryClient + static yaml + the
            // in-memory RouteDefinitionRepository) at once.
            // One event = one refresh = cheap.
            //
            // Order matters: the event only re-reads what the
            // repository already holds, so a save() after the
            // publish would not take effect until the NEXT
            // poll. (Before this was fixed the defs list was
            // built and then dropped on the floor entirely,
            // so no catalog route ever reached the routing
            // table and every /api/<prefix>/** request 404'd.)
            //
            // See toRouteDefinitions for why REST rows are skipped.
            List<RouteDefinition> defs = toRouteDefinitions(routes);
            Set<String> nextIds = new LinkedHashSet<>();
            for (RouteDefinition def : defs) {
                routeWriter.save(Mono.just(def)).block();
                nextIds.add(def.getId());
            }
            // Drop routes we published on an earlier poll whose
            // catalog row is gone. delete() errors when the id
            // is already absent, which is benign here — another
            // refresh may have removed it — so it's swallowed.
            for (String stale : publishedIds) {
                if (!nextIds.contains(stale)) {
                    routeWriter.delete(Mono.just(stale))
                            .onErrorResume(e -> Mono.empty())
                            .block();
                    log.info("Catalog refresh: removed stale route {}", stale);
                }
            }
            publishedIds.clear();
            publishedIds.addAll(nextIds);
            publisher.publishEvent(new RefreshRoutesEvent(this));
            lastPublishedCount.set(defs.size());
            log.info("Catalog refresh: published {} catalog routes", defs.size());
            meters.counter("gateway.catalog.refresh",
                    Tags.of("outcome", "success")).increment();
            meters.counter("gateway.catalog.routes_published").increment(defs.size());
        } catch (Exception e) {
            log.warn("Catalog route refresh failed (keeping previous {} routes): {}",
                    lastPublishedCount.get(), e.getMessage());
            meters.counter("gateway.catalog.refresh",
                    Tags.of("outcome", "failure")).increment();
        }
    }

    /**
     * Select the catalog rows the gateway owns and map them to
     * route definitions.
     *
     * <p>Only {@code kind=QUERY} rows are ours. The REST rows in
     * the same feed (sso-admin, auth-center) describe prefixes
     * that {@code application.yml} already routes with
     * hand-tuned per-path {@code StripPrefix} values —
     * {@code /api/auth/refresh} strips 1 segment while
     * {@code /api/auth/login} strips 2. A generated
     * {@code Path=/api/auth/**} route would collide with those
     * and break login/refresh. Dynamic routing exists for
     * provisioned query instances, which have no YAML
     * counterpart; the REST surface stays statically owned.
     */
    static List<RouteDefinition> toRouteDefinitions(List<GatewayRouteDto> routes) {
        List<RouteDefinition> defs = new ArrayList<>(routes.size());
        for (GatewayRouteDto r : routes) {
            if (!QUERY_KIND.equalsIgnoreCase(r.kind())) {
                continue;
            }
            defs.add(toRouteDefinition(r));
        }
        return defs;
    }

    /**
     * Translate one DTO into a {@link RouteDefinition} suitable
     * for the Spring Cloud Gateway pipeline. Predicate =
     * {@code Path=<requestUri>}. Filter = {@code StripPrefix=<N>}
     * when {@code N > 0} (some legacy prefixes like {@code /qs}
     * have a 1-segment strip; a hypothetical root-level
     * wildcard would have 0).
     */
    static RouteDefinition toRouteDefinition(GatewayRouteDto r) {
        RouteDefinition def = new RouteDefinition();
        def.setId("catalog-" + r.serviceId());
        def.setUri(URI.create("lb://" + r.serviceId()));
        def.setPredicates(List.of(
                new PredicateDefinition("Path=" + r.requestUri())));
        if (r.stripPrefix() > 0) {
            def.setFilters(List.of(
                    new FilterDefinition("StripPrefix=" + r.stripPrefix())));
        }
        return def;
    }
}
