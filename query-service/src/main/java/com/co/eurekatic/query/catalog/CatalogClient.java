package com.co.eurekatic.query.catalog;

import com.co.eurekatic.query.config.CatalogClientProps;
import com.co.eurekatic.query.observability.QueryMetrics;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.server.ResponseStatusException;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Thin HTTP client for sso-admin's catalog endpoints.
 *
 * <p>Three flavors of call:
 * <ul>
 *   <li>{@link #fetchQuery} / {@link #fetchWrite} — per-row
 *       calls with the caller's bearer JWT. Authorization
 *       happens inside sso-admin.</li>
 *   <li>{@link #fetchPathTemplates} — internal call to
 *       {@code /internal/pathTemplates}, gated by the
 *       {@code X-Internal-Token} header (V30). The header
 *       value is operator-configured (see
 *       {@code query.catalog.internal-token}). When the
 *       token is empty or unset, calls fail closed — better
 *       than accidentally calling an endpoint that should
 *       be unreachable from outside the docker network.</li>
 * </ul>
 *
 * <p>Why we re-validate the JWT locally instead of trusting
 * the gateway's {@code X-Authenticated-User} headers: the
 * query-service may be exposed directly to a partner (the
 * spec mentions "federated access"), in which case the
 * gateway is bypassed. See {@code security.JwtAuthenticationFilter}
 * for the local validation path.
 */
@Component
public class CatalogClient {

    private static final Logger log = LoggerFactory.getLogger(CatalogClient.class);

    /** V30 — shared secret the path-registry uses against
     *  sso-admin's {@code /internal/pathTemplates}. Configured
     *  in {@code query.catalog.internal-token}; must match
     *  sso-admin's {@code sso.internal.token}. */
    static final String INTERNAL_HEADER = "X-Internal-Token";

    private final RestClient client;
    private final String internalToken;
    private final QueryMetrics metrics;

    public CatalogClient(CatalogClientProps props,
                          QueryMetrics metrics,
                          @Value("${query.catalog.internal-token:}") String internalToken) {
        // RestClient is the modern sync HTTP client in
        // Boot 4 (replaces RestTemplate). We don't use the
        // reactive variant because the read/write paths
        // here are blocking JDBC anyway; turning the
        // catalog call into Mono<Foo> would force the
        // entire request thread to switch on every hop.
        this.client = RestClient.builder()
                .baseUrl(Objects.requireNonNull(
                        props.getBaseUrl(),
                        "query.catalog.base-url is required"))
                .defaultHeader(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE)
                .build();
        this.internalToken = internalToken;
        this.metrics = metrics;
        if (internalToken == null || internalToken.isBlank()) {
            log.warn("query.catalog.internal-token is not set; "
                    + "the path-registry will refuse to refresh and dispatch "
                    + "will return 503 for path-template queries. Set the env var "
                    + "to the same value as sso-admin's sso.internal.token.");
        } else {
            log.info("CatalogClient: internal token configured (length={})",
                    internalToken.length());
        }
    }

    /**
     * Fetches the query definition for {@code uuid}.
     *
     * @param bearer the caller's raw bearer token (without
     *               the {@code "Bearer "} prefix). sso-admin
     *               re-parses it.
     * @param uuid   the uuid of the query to resolve.
     * @return the parsed query row.
     * @throws ResponseStatusException 404 if sso-admin
     *         reports the uuid is unknown OR the caller has
     *         no role bound to it (the catalog deliberately
     *         returns 403 for both). 503 if sso-admin is
     *         unreachable.
     */
    public QueryDefinition fetchQuery(String bearer, String uuid) {
        long start = System.nanoTime();
        try {
            ResponseEntity<QueryDefinition> resp = client.get()
                    .uri(uri -> uri.path("/getQuery").queryParam("uuid", uuid).build())
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "El catálogo rechazó la consulta: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Error del servidor de catálogo: " + res.getStatusText());
                    })
                    .toEntity(QueryDefinition.class);
            metrics.recordCatalogCall("getQuery",
                    QueryMetrics.Outcome.SUCCESS, System.nanoTime() - start);
            return resp.getBody();
        } catch (RestClientException | ResponseStatusException e) {
            metrics.recordCatalogCall("getQuery",
                    QueryMetrics.Outcome.FAILURE, System.nanoTime() - start);
            if (e instanceof ResponseStatusException rse) throw rse;
            log.warn("Catalog call /getQuery?uuid={} failed: {}", uuid, e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "El catálogo de sso-admin no está disponible", e);
        }
    }

    /**
     * Fetches the write definition for {@code uuid}. Same
     * contract as {@link #fetchQuery}.
     */
    public WriteDefinition fetchWrite(String bearer, String uuid) {
        long start = System.nanoTime();
        try {
            ResponseEntity<WriteDefinition> resp = client.get()
                    .uri(uri -> uri.path("/getWrite").queryParam("uuid", uuid).build())
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "Catalog refused write: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Catalog server error: " + res.getStatusText());
                    })
                    .toEntity(WriteDefinition.class);
            metrics.recordCatalogCall("getWrite",
                    QueryMetrics.Outcome.SUCCESS, System.nanoTime() - start);
            return resp.getBody();
        } catch (RestClientException | ResponseStatusException e) {
            metrics.recordCatalogCall("getWrite",
                    QueryMetrics.Outcome.FAILURE, System.nanoTime() - start);
            if (e instanceof ResponseStatusException rse) throw rse;
            log.warn("Catalog call /getWrite?uuid={} failed: {}", uuid, e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "sso-admin catalog unavailable", e);
        }
    }

    /**
     * V27 — fetches every query the bearer is authorized to
     * see, for the in-memory {@code QueryPathRegistry} to
     * build its path-template → uuid map. Uses the same
     * catalog endpoint the consumer UI uses
     * ({@code GET /myQueries}), so it respects the same
     * per-row role auth.
     *
     * <p>No microserviceId filter today — the registry
     * filters client-side via the catalog's authorization
     * (the bearer token). A future {@code /myPathTemplates}
     * endpoint could narrow the result set server-side for
     * efficiency; the current overhead is acceptable
     * (catalog has &lt; 1k queries in practice).
     */
    public java.util.List<QueryDefinition> fetchAllQueries(String bearer) {
        try {
            QueryDefinition[] arr = client.get()
                    .uri("/myQueries")
                    .header(HttpHeaders.AUTHORIZATION,
                            "Bearer " + (bearer == null ? "" : bearer))
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "Catalog refused myQueries: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Catalog server error: " + res.getStatusText());
                    })
                    .body(QueryDefinition[].class);
            return arr == null ? java.util.List.of() : java.util.Arrays.asList(arr);
        } catch (RestClientException e) {
            log.warn("Catalog call /myQueries failed: {}", e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "sso-admin catalog unavailable", e);
        }
    }

    /**
     * V30 — fetches every query row whose {@code path_template}
     * is non-null, optionally filtered by microservice. Calls
     * the internal {@code /internal/pathTemplates} endpoint,
     * authenticated by the {@code X-Internal-Token} header
     * (operator-configured via {@code query.catalog.internal-token}).
     *
     * <p>Unlike {@link #fetchAllQueries}, this does NOT take
     * a bearer token — the internal endpoint is gated on
     * the shared secret alone, because the registry isn't
     * acting on behalf of any user. Per-request user auth
     * still happens downstream via {@link #fetchQuery}.
     *
     * @param microserviceId optional filter; null = all
     *                       path-template queries
     */
    public List<QueryDefinition> fetchPathTemplates(Long microserviceId) {
        if (internalToken == null || internalToken.isBlank()) {
            log.warn("fetchPathTemplates called but internal token is not configured");
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "query.catalog.internal-token is not configured on this instance");
        }
        long start = System.nanoTime();
        try {
            QueryDefinition[] arr = client.get()
                    .uri(uri -> uri.path("/internal/pathTemplates")
                            .queryParam("microserviceId",
                                    microserviceId == null ? "" : microserviceId.toString())
                            .build())
                    .header(INTERNAL_HEADER, internalToken)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "Catalog refused pathTemplates: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Catalog server error: " + res.getStatusText());
                    })
                    .body(QueryDefinition[].class);
            metrics.recordCatalogCall("pathTemplates",
                    QueryMetrics.Outcome.SUCCESS, System.nanoTime() - start);
            return arr == null ? List.of() : Arrays.asList(arr);
        } catch (RestClientException | ResponseStatusException e) {
            metrics.recordCatalogCall("pathTemplates",
                    QueryMetrics.Outcome.FAILURE, System.nanoTime() - start);
            if (e instanceof ResponseStatusException rse) throw rse;
            log.warn("Catalog call /internal/pathTemplates failed: {}", e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "sso-admin catalog unavailable", e);
        }
    }

    /**
     * V32 — internal endpoint that lets a query-service
     * container identify itself to sso-admin by its
     * instance name (set by the provisioner as
     * {@code QUERY_INSTANCE_NAME}). Returns a tiny JSON
     * body with the row's {@code microserviceId},
     * {@code serviceId}, {@code kind}, and
     * {@code instanceName}. An empty body means
     * "no matching row" (caller treats this as
     * "global" — registry stays empty rather than 404ing).
     *
     * <p>Gated by the {@code X-Internal-Token} header.
     */
    public java.util.Map<String, Object> whoami(String instanceName) {
        if (internalToken == null || internalToken.isBlank()) {
            log.warn("whoami called but internal token is not configured");
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "query.catalog.internal-token is not configured on this instance");
        }
        long start = System.nanoTime();
        try {
            @SuppressWarnings("unchecked")
            java.util.Map<String, Object> body = client.get()
                    .uri(uri -> uri.path("/internal/whoami")
                            .queryParam("instanceName", instanceName)
                            .build())
                    .header(INTERNAL_HEADER, internalToken)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "Catalog refused whoami: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Catalog server error: " + res.getStatusText());
                    })
                    .body(java.util.Map.class);
            metrics.recordCatalogCall("whoami",
                    QueryMetrics.Outcome.SUCCESS, System.nanoTime() - start);
            return body == null ? java.util.Map.of() : body;
        } catch (RestClientException | ResponseStatusException e) {
            metrics.recordCatalogCall("whoami",
                    QueryMetrics.Outcome.FAILURE, System.nanoTime() - start);
            if (e instanceof ResponseStatusException rse) throw rse;
            log.warn("Catalog call /internal/whoami failed: {}", e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "sso-admin catalog unavailable", e);
        }
    }
        try {
            ResponseEntity<WriteDefinition> resp = client.get()
                    .uri(uri -> uri.path("/getWrite").queryParam("uuid", uuid).build())
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "El catálogo rechazó la escritura: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Error del servidor de catálogo: " + res.getStatusText());
                    })
                    .toEntity(WriteDefinition.class);
            return resp.getBody();
        } catch (RestClientException e) {
            log.warn("Catalog call /getWrite?uuid={} failed: {}", uuid, e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "El catálogo de sso-admin no está disponible", e);
        }
    }
}