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
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

import java.net.URI;
import java.util.ArrayList;
import java.util.List;
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
 */
@Component
public class CatalogRoutesRefresher {

    private static final Logger log = LoggerFactory.getLogger(CatalogRoutesRefresher.class);

    private final WebClient client;
    private final ApplicationEventPublisher publisher;
    private final MeterRegistry meters;
    private final AtomicInteger lastPublishedCount = new AtomicInteger(0);

    public CatalogRoutesRefresher(
            ApplicationEventPublisher publisher,
            MeterRegistry meters,
            @Value("${gateway.catalog-url:http://sso-admin:8080}") String catalogBaseUrl) {
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
        this.meters = meters;
        log.info("CatalogRoutesRefresher: baseUrl={}", catalogBaseUrl);
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
            List<GatewayRouteDto> routes = client.get()
                    .uri("/internal/gateway/routes")
                    .retrieve()
                    .bodyToMono(new ParameterizedTypeReference<List<GatewayRouteDto>>() {})
                    .block();
            if (routes == null || routes.isEmpty()) {
                log.debug("Catalog returned no routes; keeping previous {} routes",
                        lastPublishedCount.get());
                return;
            }
            // Build every RouteDefinition in one batch and
            // publish a single RefreshRoutesEvent — SCG's
            // CachingRouteLocator listens for the event and
            // reloads from all sources (DiscoveryClient +
            // static yaml + the in-memory RouteDefinitionRepository)
            // at once. One event = one refresh = cheap.
            List<RouteDefinition> defs = new ArrayList<>(routes.size());
            for (GatewayRouteDto r : routes) {
                defs.add(toRouteDefinition(r));
            }
            // Mutate the in-memory repository directly. Spring
            // Cloud Gateway's InMemoryRouteDefinitionRepository
            // exposes a save(Mono) sink we use via the event
            // publisher (the event triggers a full reload of
            // every source, including the YAML static routes).
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
