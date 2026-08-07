package com.co.eurekatic.gateway.openapi;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.util.List;
import java.util.Map;

/**
 * Reactive controller that serves the aggregated OpenAPI document.
 *
 * <p>The two endpoints live under {@code /api/docs/v3/api-docs}:
 * <ul>
 *   <li>{@code GET /api/docs/v3/api-docs} → the merged doc across
 *       every configured service. Powers Swagger UI.</li>
 *   <li>{@code GET /api/docs/v3/api-docs/swagger-config} → the
 *       config block Swagger UI expects (url of the spec, etc.).</li>
 *   <li>{@code GET /api/docs/v3/api-docs/{serviceId}} → the spec of
 *       one service, paths NOT rewritten. Useful for debugging a
 *       single downstream directly.</li>
 * </ul>
 *
 * <p>All three are produced by {@link OpenApiAggregatorService}
 * which caches the merged result with a Caffeine TTL
 * ({@code springdoc.cache.ttl}).
 *
 * <p>This controller overrides springdoc's own
 * {@code /v3/api-docs} controller by virtue of
 * {@code springdoc.api-docs.enabled=false} in application.yml —
 * we want our merged doc, not whatever the gateway's own
 * (empty) classpath would produce.
 */
@RestController
public class OpenApiAggregatorController {

    private final OpenApiAggregatorService aggregator;

    public OpenApiAggregatorController(OpenApiAggregatorService aggregator) {
        this.aggregator = aggregator;
    }

    @GetMapping(value = "/api/docs/v3/api-docs",
            produces = "application/json")
    public Mono<Map<String, Object>> merged() {
        return aggregator.aggregated();
    }

    @GetMapping(value = "/api/docs/v3/api-docs/swagger-config",
            produces = "application/json")
    public Map<String, Object> swaggerConfig() {
        // Matches the shape springdoc's auto-generated swagger-config
        // emits, so the Swagger UI bundle loads without modification.
        return Map.of(
                "configUrl", "/api/docs/v3/api-docs/swagger-config",
                "url", "/api/docs/v3/api-docs",
                "urls", List.of(Map.of(
                        "url", "/api/docs/v3/api-docs",
                        "name", "SSO Platform API (aggregated)"))
        );
    }

    @GetMapping(value = "/api/docs/v3/api-docs/{serviceId}",
            produces = "application/json")
    public Mono<Map<String, Object>> single(@PathVariable String serviceId) {
        return aggregator.single(serviceId);
    }
}
