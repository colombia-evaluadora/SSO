package com.co.eurekatic.gateway.openapi;

import com.co.eurekatic.common.dto.OpenApiCatalogEntry;
import com.github.benmanes.caffeine.cache.Cache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.client.ServiceInstance;
import org.springframework.cloud.client.discovery.ReactiveDiscoveryClient;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.TreeMap;

/**
 * Reactive aggregator that produces a single OpenAPI 3.1 document
 * for every microservice the gateway knows about.
 *
 * <h2>Dual-source merge strategy</h2>
 * <ul>
 *   <li><b>Springdoc source</b> (default): fetch the service's
 *       own {@code /v3/api-docs} via Eureka + WebClient, rewrite
 *       paths to the gateway prefix, merge {@code components.schemas}
 *       namespaced under {@code <serviceId>.<TypeName>} (so two
 *       services with the same DTO name don't collide), merge
 *       tags.</li>
 *   <li><b>Catalog source</b>: poll sso-admin's
 *       {@code GET /internal/openapi/catalog?serviceId=…} and
 *       translate each {@link OpenApiCatalogEntry} into a stub
 *       operation under the gateway prefix declared in
 *       {@link ServiceGatewayMapping#gatewayPaths()}.</li>
 * </ul>
 *
 * <p>Failures are absorbed per-service: a 404 or 503 from one
 * downstream logs a warning and contributes zero paths to the
 * merged doc, rather than failing the whole build. The cache
 * ({@code springdoc.cache.ttl}) shields downstream services from
 * request-rate.
 *
 * <p>The merged doc's {@code servers[0].url} is fixed at
 * {@code "/"} so Swagger UI's "Try it out" sends requests to the
 * gateway's own origin.
 */
@Service
public class OpenApiAggregatorService {

    private static final Logger log = LoggerFactory.getLogger(OpenApiAggregatorService.class);
    private static final String MERGED_CACHE_KEY = "merged";
    private static final String SINGLE_CACHE_KEY_PREFIX = "single:";

    private final ReactiveDiscoveryClient discovery;
    private final WebClient.Builder webClientBuilder;
    private final Cache<String, Map<String, Object>> cache;
    private final List<ServiceGatewayMapping> mappings;
    private final String catalogUrl;
    private final String internalToken;

    public OpenApiAggregatorService(
            ReactiveDiscoveryClient discovery,
            WebClient.Builder webClientBuilder,
            Cache<String, Map<String, Object>> cache,
            List<ServiceGatewayMapping> mappings,
            @Value("${springdoc.aggregator.catalog-url:}") String catalogUrl,
            @Value("${springdoc.aggregator.catalog-internal-token:}") String internalToken) {
        this.discovery = discovery;
        this.webClientBuilder = webClientBuilder;
        this.cache = cache;
        this.mappings = mappings;
        this.catalogUrl = catalogUrl;
        this.internalToken = internalToken;
    }

    /**
     * Build the merged OpenAPI doc across every configured service.
     * Returns the cached value if present.
     */
    public Mono<Map<String, Object>> aggregated() {
        return Mono.fromSupplier(() -> cache.get(MERGED_CACHE_KEY, key -> buildMerged()))
                // buildMerged() is blocking on purpose — it fans out to
                // every service with WebClient + .block(Duration). Without
                // this, the supplier runs on whatever non-blocking thread
                // subscribed (a Netty event loop for HTTP traffic, parallel-N
                // for the scheduled warmup) and Reactor's blocking guard
                // throws on the FIRST .block() of every fetch:
                //   IllegalStateException: block()/blockFirst()/blockLast()
                //   are blocking, which is not supported in thread parallel-1
                // Each fetch is individually try/caught and logged as a WARN
                // "Failed to merge OpenAPI for service=... — skipping", so
                // the endpoint still answered 200 — with an empty doc. Swagger
                // UI rendered a page with zero endpoints and no error, which
                // is why this went unnoticed.
                .subscribeOn(Schedulers.boundedElastic());
    }

    /**
     * Build the OpenAPI doc for a single service id, with paths
     * prefixed by the gateway as configured. Returns the cached
     * value if present.
     */
    public Mono<Map<String, Object>> single(String serviceId) {
        return Mono.fromSupplier(() -> cache.get(
                        SINGLE_CACHE_KEY_PREFIX + serviceId,
                        key -> buildSingle(serviceId)))
                // Same blocking-on-a-reactive-thread problem as aggregated().
                .subscribeOn(Schedulers.boundedElastic());
    }

    /* ====================== builders ====================== */

    private Map<String, Object> buildMerged() {
        Map<String, Object> merged = new LinkedHashMap<>();
        merged.put("openapi", "3.1.0");
        merged.put("info", Map.of(
                "title", "SSO Platform API (aggregated)",
                "version", "1.0",
                "description", "Auto-generated by api-gateway from the OpenAPI specs of "
                        + mappings.size() + " microservice(s). Last built at " + Instant.now()
                        + "."));
        // Relative path so Swagger UI's "Try it out" sends to the
        // gateway's origin (window.location.origin + "/" + path).
        merged.put("servers", List.of(Map.of("url", "/")));

        // TreeMap keeps paths sorted alphabetically in the rendered doc.
        Map<String, Object> paths = new TreeMap<>();
        Map<String, Object> components = new LinkedHashMap<>();
        Map<String, Object> tags = new LinkedHashMap<>();

        if (mappings.isEmpty()) {
            log.warn("No springdoc.aggregator.services configured; the merged doc will be empty. "
                    + "Add at least one entry to springdoc.aggregator.services in application.yml.");
        }

        for (ServiceGatewayMapping mapping : mappings) {
            try {
                switch (mapping.source()) {
                    case SPRINGDOC -> mergeSpringdocService(paths, components, tags, mapping);
                    case CATALOG -> mergeCatalogService(paths, components, tags, mapping);
                }
            } catch (RuntimeException e) {
                log.warn("Failed to merge OpenAPI for service={} source={}: {}",
                        mapping.serviceId(), mapping.source(), e.toString());
            }
        }

        merged.put("paths", paths);
        if (!components.isEmpty()) {
            merged.put("components", components);
        }
        merged.put("tags", new ArrayList<>(tags.values()));
        return merged;
    }

    private Map<String, Object> buildSingle(String serviceId) {
        // For /api/docs/v3/api-docs/{serviceId} we return the service's
        // own spec as-is (paths NOT rewritten). Useful for debugging
        // a single downstream without going through the gateway.
        ServiceInstance instance = pickInstance(serviceId)
                .orElseThrow(() -> new IllegalStateException(
                        "No Eureka instance available for serviceId=" + serviceId));
        URI base = instance.getUri();
        return webClientBuilder.baseUrl(base.toString()).build()
                .get()
                .uri("/v3/api-docs")
                .retrieve()
                .bodyToMono(Map.class)
                .block(Duration.ofSeconds(10));
    }

    /* ====================== per-source merge ====================== */

    @SuppressWarnings("unchecked")
    private void mergeSpringdocService(Map<String, Object> paths,
                                       Map<String, Object> components,
                                       Map<String, Object> tags,
                                       ServiceGatewayMapping mapping) {
        ServiceInstance instance = pickInstance(mapping.serviceId()).orElse(null);
        if (instance == null) {
            log.warn("Skipping springdoc merge for service={}: no Eureka instance is UP. "
                    + "If the service is intentionally absent, mark it source=CATALOG instead.",
                    mapping.serviceId());
            return;
        }

        Map<String, Object> doc;
        try {
            doc = webClientBuilder.baseUrl(instance.getUri().toString()).build()
                    .get().uri("/v3/api-docs")
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block(Duration.ofSeconds(10));
        } catch (WebClientResponseException e) {
            log.warn("Springdoc fetch failed for service={}: HTTP {} — skipping",
                    mapping.serviceId(), e.getStatusCode().value());
            return;
        } catch (RuntimeException e) {
            log.warn("Springdoc fetch failed for service={}: {} — skipping",
                    mapping.serviceId(), e.toString());
            return;
        }
        if (doc == null) {
            log.warn("Springdoc fetch for service={} returned null body — skipping", mapping.serviceId());
            return;
        }

        // Rewrite the service-local paths onto their gateway-facing
        // form. A gatewayPaths entry means one of two different things
        // and they must NOT be treated alike:
        //
        //   "/api/auth/**"  — a PREFIX. The gateway strips it and
        //                     forwards the rest, so every service path
        //                     appears underneath it.
        //   "/getApiToken"  — an EXACT path. The gateway forwards it
        //                     unchanged, so it maps to the identically
        //                     named path on the service — it is not a
        //                     prefix for anything.
        //
        // This used to cross-product every entry with every service
        // path, which turned auth-center's 8 endpoints into 72 and
        // invented routes that do not exist: /getApiToken/auth/logout,
        // /myApps/getInfoUser, /api/auth/auth/logout. Swagger UI
        // rendered all of them as if they were real.
        Map<String, Object> docPaths = (Map<String, Object>) doc.getOrDefault("paths", Map.of());
        for (String gatewayPath : mapping.gatewayPaths()) {
            if (isPrefix(gatewayPath)) {
                String prefix = stripWildcard(gatewayPath);
                // A prefix route is one of two shapes and the config
                // does not say which, because gatewayPaths carries no
                // StripPrefix value. We infer it:
                //
                //   pass-through — the gateway forwards the path
                //     unchanged, so the downstream's own paths already
                //     start with the prefix (/auth/** -> /auth/refresh).
                //     Emit only those, unprefixed-again.
                //   strip-prefix — the gateway removes the prefix before
                //     forwarding, so no downstream path starts with it
                //     (/api/auth/** -> /getApiToken). Emit prefix + path.
                //
                // Concatenating unconditionally produced doubled paths
                // (/auth/auth/refresh) and, worse, glued every unrelated
                // endpoint onto narrow prefixes
                // (/internal/cache/getApiToken).
                boolean passThrough = docPaths.keySet().stream()
                        .anyMatch(p -> p.startsWith(prefix));
                for (var entry : docPaths.entrySet()) {
                    if (passThrough) {
                        if (entry.getKey().startsWith(prefix)) {
                            putPath(paths, mapping, entry.getKey(), entry.getValue());
                        }
                    } else {
                        putPath(paths, mapping, joinPath(prefix, entry.getKey()), entry.getValue());
                    }
                }
            } else {
                // Exact route: only emit it when the service actually
                // declares that path. Emitting it unconditionally would
                // document an endpoint the downstream does not serve
                // (e.g. /login is routed by the gateway but lives on a
                // controller springdoc does not pick up).
                Object op = docPaths.get(gatewayPath);
                if (op != null) {
                    putPath(paths, mapping, gatewayPath, op);
                }
            }
        }

        // Merge components.schemas under <serviceId>.<TypeName>.
        Map<String, Object> docComponents =
                (Map<String, Object>) doc.getOrDefault("components", Map.of());
        Map<String, Object> docSchemas =
                (Map<String, Object>) docComponents.getOrDefault("schemas", Map.of());
        Map<String, Object> mergedSchemas = (Map<String, Object>) components
                .computeIfAbsent("schemas", k -> new LinkedHashMap<>());
        for (var schemaEntry : docSchemas.entrySet()) {
            String namespaced = mapping.serviceId() + "." + schemaEntry.getKey();
            mergedSchemas.put(namespaced, schemaEntry.getValue());
        }

        tags.putIfAbsent(mapping.tagPrefix(), buildTag(mapping));
    }

    @SuppressWarnings("unchecked")
    private void mergeCatalogService(Map<String, Object> paths,
                                     Map<String, Object> components,
                                     Map<String, Object> tags,
                                     ServiceGatewayMapping mapping) {
        if (catalogUrl == null || catalogUrl.isBlank()) {
            log.warn("Catalog source requested for service={} but springdoc.aggregator.catalog-url "
                    + "is not set — skipping", mapping.serviceId());
            return;
        }
        if (internalToken == null || internalToken.isBlank()) {
            log.warn("Catalog source requested for service={} but springdoc.aggregator.catalog-internal-token "
                    + "is not set — skipping (set SSO_INTERNAL_TOKEN or the YAML property)", mapping.serviceId());
            return;
        }

        String prefix = mapping.gatewayPaths().isEmpty()
                ? ""
                : stripWildcard(mapping.gatewayPaths().get(0));

        List<OpenApiCatalogEntry> entries;
        try {
            entries = webClientBuilder.baseUrl(catalogUrl).build()
                    .get()
                    .uri(uriBuilder -> uriBuilder
                            .path("/internal/openapi/catalog")
                            .queryParam("serviceId", mapping.serviceId())
                            .build())
                    .header("X-Internal-Token", internalToken)
                    .retrieve()
                    .bodyToFlux(OpenApiCatalogEntry.class)
                    .collectList()
                    .block(Duration.ofSeconds(10));
        } catch (WebClientResponseException e) {
            log.warn("Catalog fetch failed for service={}: HTTP {} — skipping",
                    mapping.serviceId(), e.getStatusCode().value());
            return;
        } catch (RuntimeException e) {
            log.warn("Catalog fetch failed for service={}: {} — skipping",
                    mapping.serviceId(), e.toString());
            return;
        }
        if (entries == null) {
            return;
        }
        for (OpenApiCatalogEntry entry : entries) {
            String gatewayPath = joinPath(prefix, entry.path());
            Map<String, Object> op = buildCatalogOperation(entry, mapping.tagPrefix());
            paths.put(gatewayPath, op);
        }
        tags.putIfAbsent(mapping.tagPrefix(), buildTag(mapping));
    }

    /* ====================== helpers ====================== */

    private java.util.Optional<ServiceInstance> pickInstance(String serviceId) {
        // ReactiveDiscoveryClient returns Flux<ServiceInstance>;
        // .stream() doesn't exist on Flux. blockFirst() pulls the
        // first emission off the publisher (the registry is
        // typically a finite Flux with one entry per replica, so
        // first-iteration is enough for the gateway's
        // "send-the-doc-to-any-replica" load-balancing intent).
        return Optional.ofNullable(discovery.getInstances(serviceId).blockFirst());
    }

    /**
     * True when a {@code gatewayPaths} entry is a prefix pattern
     * ({@code /api/auth/**}) rather than an exact route
     * ({@code /getApiToken}). Only prefixes get concatenated with the
     * downstream's own paths.
     */
    private static boolean isPrefix(String p) {
        return p != null && (p.endsWith("/**") || p.endsWith("/*"));
    }

    /**
     * Add one rewritten path to the merged document, tagged with the
     * owning service. Last writer wins on collision; the tag is what
     * disambiguates two services exposing the same gateway path.
     */
    @SuppressWarnings("unchecked")
    private static void putPath(Map<String, Object> paths,
                                ServiceGatewayMapping mapping,
                                String path,
                                Object operations) {
        Map<String, Object> op = new LinkedHashMap<>((Map<String, Object>) operations);
        attachTag(op, mapping.tagPrefix(), path);
        paths.put(path, op);
    }

    private static String stripWildcard(String p) {
        if (p == null) return "";
        if (p.endsWith("/**")) return p.substring(0, p.length() - 3);
        if (p.endsWith("/*")) return p.substring(0, p.length() - 2);
        return p;
    }

    private static String joinPath(String prefix, String suffix) {
        if (prefix == null || prefix.isEmpty()) return suffix;
        if (suffix == null || suffix.isEmpty()) return prefix;
        if (prefix.endsWith("/") && suffix.startsWith("/")) {
            return prefix + suffix.substring(1);
        }
        if (!prefix.endsWith("/") && !suffix.startsWith("/")) {
            return prefix + "/" + suffix;
        }
        return prefix + suffix;
    }

    @SuppressWarnings("unchecked")
    private static void attachTag(Map<String, Object> operation, String tagPrefix, String path) {
        List<String> existing = (List<String>) operation.getOrDefault("tags", new ArrayList<>());
        List<String> tagged = new ArrayList<>(existing);
        if (!tagged.contains(tagPrefix)) {
            tagged.add(tagPrefix);
        }
        operation.put("tags", tagged);
    }

    private static Map<String, Object> buildTag(ServiceGatewayMapping mapping) {
        Map<String, Object> t = new LinkedHashMap<>();
        t.put("name", mapping.tagPrefix());
        if (mapping.description() != null && !mapping.description().isBlank()) {
            t.put("description", mapping.description());
        }
        return t;
    }

    private static Map<String, Object> buildCatalogOperation(OpenApiCatalogEntry entry, String tagPrefix) {
        Map<String, Object> op = new LinkedHashMap<>();
        op.put("summary", entry.description() == null || entry.description().isBlank()
                ? entry.method() + " " + entry.path()
                : entry.description());
        op.put("description", "External service endpoint registered in sso-admin's endpoint catalog. "
                + "Roles: " + (entry.roles() == null || entry.roles().isEmpty()
                        ? "(none declared)"
                        : String.join(", ", entry.roles())));
        op.put("tags", List.of(tagPrefix));
        op.put("operationId", (entry.serviceId() == null ? "external" : entry.serviceId())
                + "_" + entry.method().toLowerCase()
                + "_" + entry.path().replaceAll("[^A-Za-z0-9]+", "_"));
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("description", "See the upstream service's actual API for the response shape.");
        op.put("responses", Map.of("200", response));
        return op;
    }
}
