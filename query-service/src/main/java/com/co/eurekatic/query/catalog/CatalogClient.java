package com.co.eurekatic.query.catalog;

import com.co.eurekatic.query.config.CatalogClientProps;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.server.ResponseStatusException;

import java.util.Map;
import java.util.Objects;

/**
 * Thin HTTP client for sso-admin's catalog endpoints.
 *
 * <p>Two methods: {@link #fetchQuery(String, String)} and
 * {@link #fetchWrite(String, String)}. Each takes the caller's
 * access token and forwards it as {@code Authorization:
 * Bearer ...}; sso-admin's JwtAuthenticationFilter parses
 * it, and the per-row role check inside the catalog service
 * enforces authorization. The query-service has no business
 * knowing who owns which query — that's the catalog's job.
 *
 * <p>Why we re-validate the JWT locally instead of trusting
 * the gateway's {@code X-Authenticated-User} headers: the
 * query-service may be exposed directly to a partner (the
 * spec mentions "federated access"), in which case the
 * gateway is bypassed. See {@code security.JwtAuthenticationFilter}
 * for the local validation path.
 *
 * <p>The two endpoints return JSON shapes that match the
 * wire format the sso-admin catalog uses
 * ({@link com.co.eurekatic.common.security.AuthPrincipal}
 * username + the original uppercase keys for backward
 * compatibility with downstream consumers that parsed the
 * legacy sso-service response).
 */
@Component
public class CatalogClient {

    private static final Logger log = LoggerFactory.getLogger(CatalogClient.class);

    private final RestClient client;

    public CatalogClient(CatalogClientProps props) {
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
        try {
            ResponseEntity<QueryDefinition> resp = client.get()
                    .uri(uri -> uri.path("/getQuery").queryParam("uuid", uuid).build())
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(),
                                "Catalog refused query: " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatusCode.valueOf(503),
                                "Catalog server error: " + res.getStatusText());
                    })
                    .toEntity(QueryDefinition.class);
            return resp.getBody();
        } catch (RestClientException e) {
            log.warn("Catalog call /getQuery?uuid={} failed: {}", uuid, e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "sso-admin catalog unavailable", e);
        }
    }

    /**
     * Fetches the write definition for {@code uuid}. Same
     * contract as {@link #fetchQuery}.
     */
    public WriteDefinition fetchWrite(String bearer, String uuid) {
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
            return resp.getBody();
        } catch (RestClientException e) {
            log.warn("Catalog call /getWrite?uuid={} failed: {}", uuid, e.getMessage());
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                    "sso-admin catalog unavailable", e);
        }
    }
}