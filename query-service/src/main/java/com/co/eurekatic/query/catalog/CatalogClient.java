package com.co.eurekatic.query.catalog;

import com.co.eurekatic.query.config.CatalogClientProps;
import com.co.eurekatic.query.observability.QueryMetrics;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.web.util.UriBuilder;

import java.net.URI;
import java.net.http.HttpClient;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Function;

/**
 * Thin HTTP client for sso-admin's catalog endpoints.
 *
 * <p>Two flavors of authentication:
 * <ul>
 *   <li>{@link #fetchQuery} / {@link #fetchWrite} / {@link #fetchAllQueries}
 *       — per-row calls carrying the caller's bearer JWT. Authorization
 *       happens inside sso-admin (per-row role intersection).</li>
 *   <li>{@link #fetchPathTemplates} / {@link #whoami} — internal calls
 *       gated by the {@code X-Internal-Token} header, operator-configured
 *       via {@code query.catalog.internal-token}. The registry isn't acting
 *       on behalf of any user, so there is no bearer to forward. When the
 *       token is empty or unset these fail closed — better than calling an
 *       endpoint that should be unreachable from outside the docker
 *       network.</li>
 * </ul>
 *
 * <p>Why we re-validate the JWT locally instead of trusting the gateway's
 * {@code X-Authenticated-User} headers: query-service may be exposed
 * directly to a partner ("federated access"), in which case the gateway is
 * bypassed. See {@code security.JwtAuthenticationFilter}.
 *
 * <p><b>Every call is bounded by {@link CatalogClientProps}' connect and
 * read timeouts.</b> This matters more than it looks: the catalog
 * round-trip sits on the hot path of EVERY request, and a
 * {@code RestClient} built without an explicit request factory inherits the
 * JDK {@code HttpClient} default of no read timeout at all. An sso-admin
 * that accepts the connection and then stops answering would park request
 * threads forever — until the whole Tomcat pool is gone and this service
 * stops answering its own health probe, so the container is never
 * restarted either.
 */
@Component
public class CatalogClient {

    private static final Logger log = LoggerFactory.getLogger(CatalogClient.class);

    /** Shared secret for sso-admin's {@code /internal/**} surface;
     *  must match sso-admin's {@code sso.internal.token}. */
    static final String INTERNAL_HEADER = "X-Internal-Token";

    private final RestClient client;
    private final String internalToken;
    private final QueryMetrics metrics;

    public CatalogClient(CatalogClientProps props,
                          QueryMetrics metrics,
                          @Value("${query.catalog.internal-token:}") String internalToken) {
        // RestClient is the sync HTTP client in Boot 4 (replaces
        // RestTemplate). Not the reactive variant: the read/write paths
        // here are blocking JDBC anyway, so a Mono<Foo> hop would only
        // force a thread switch.
        HttpClient jdk = HttpClient.newBuilder()
                .connectTimeout(props.getConnectTimeout())
                .build();
        JdkClientHttpRequestFactory factory = new JdkClientHttpRequestFactory(jdk);
        factory.setReadTimeout(props.getReadTimeout());

        this.client = RestClient.builder()
                .baseUrl(Objects.requireNonNull(
                        props.getBaseUrl(),
                        "query.catalog.base-url is required"))
                .requestFactory(factory)
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
            log.info("CatalogClient: internal token configured (length={}), "
                    + "connectTimeout={} readTimeout={}",
                    internalToken.length(), props.getConnectTimeout(), props.getReadTimeout());
        }
    }

    /**
     * Fetches the query definition for {@code uuid}.
     *
     * @param bearer the caller's raw bearer token (no {@code "Bearer "}
     *               prefix); sso-admin re-parses it.
     */
    public QueryDefinition fetchQuery(String bearer, String uuid) {
        return call("getQuery", QueryDefinition.class,
                HttpHeaders.AUTHORIZATION, "Bearer " + (bearer == null ? "" : bearer),
                uri -> uri.path("/getQuery").queryParam("uuid", uuid).build());
    }

    /** Fetches the write definition for {@code uuid}. Same contract as {@link #fetchQuery}. */
    public WriteDefinition fetchWrite(String bearer, String uuid) {
        return call("getWrite", WriteDefinition.class,
                HttpHeaders.AUTHORIZATION, "Bearer " + (bearer == null ? "" : bearer),
                uri -> uri.path("/getWrite").queryParam("uuid", uuid).build());
    }

    /**
     * Every query the bearer is authorized to see, as the consumer UI sees
     * it ({@code GET /myQueries}) — the per-user view of the catalog,
     * subject to the same per-row role check as {@link #fetchQuery}.
     *
     * <p>The path registry does NOT use this: it needs every row for its
     * microservice regardless of who is asking, which is what
     * {@link #fetchPathTemplates} answers without a user in play.
     */
    public List<QueryDefinition> fetchAllQueries(String bearer) {
        return asList(call("myQueries", QueryDefinition[].class,
                HttpHeaders.AUTHORIZATION, "Bearer " + (bearer == null ? "" : bearer),
                uri -> uri.path("/myQueries").build()));
    }

    /**
     * Every query row with a non-null {@code path_template}, optionally
     * filtered by microservice, so {@code QueryPathRegistry} can build its
     * dispatch table.
     *
     * @param microserviceId optional filter; null = all path-template queries
     */
    public List<QueryDefinition> fetchPathTemplates(Long microserviceId) {
        requireInternalToken("fetchPathTemplates");
        return asList(call("pathTemplates", QueryDefinition[].class,
                INTERNAL_HEADER, internalToken,
                uri -> uri.path("/internal/pathTemplates")
                        .queryParam("microserviceId",
                                microserviceId == null ? "" : microserviceId.toString())
                        .build()));
    }

    /**
     * Lets this container identify itself to sso-admin by its instance name
     * (set by the provisioner as {@code QUERY_INSTANCE_NAME}). Returns the
     * row's {@code microserviceId}, {@code serviceId}, {@code kind} and
     * {@code instanceName}; an empty body means "no matching row", which
     * the caller treats as "global" rather than an error.
     */
    @SuppressWarnings("unchecked")
    public Map<String, Object> whoami(String instanceName) {
        requireInternalToken("whoami");
        Map<String, Object> body = call("whoami", Map.class,
                INTERNAL_HEADER, internalToken,
                uri -> uri.path("/internal/whoami")
                        .queryParam("instanceName", instanceName)
                        .build());
        return body == null ? Map.of() : body;
    }

    /**
     * The one place a catalog call is actually made: same timeouts, same
     * status translation, same metric for all five endpoints. Each caller
     * differs only in the metric label, the URI, the auth header and the
     * response type — everything else was copy-pasted five times before.
     *
     * @param label metric tag ({@code getQuery}, {@code whoami}, …)
     */
    private <T> T call(String label, Class<T> type,
                       String authHeader, String authValue,
                       Function<UriBuilder, URI> uriFn) {
        long start = System.nanoTime();
        try {
            T body = client.get()
                    .uri(uriFn)
                    .header(authHeader, authValue)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ResponseStatusException(
                                res.getStatusCode(), refusalMessage(res.getStatusCode()));
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ResponseStatusException(
                                HttpStatus.SERVICE_UNAVAILABLE,
                                "El catálogo de sso-admin respondió con un error");
                    })
                    .body(type);
            metrics.recordCatalogCall(label, QueryMetrics.Outcome.SUCCESS,
                    System.nanoTime() - start);
            return body;
        } catch (ResponseStatusException e) {
            metrics.recordCatalogCall(label, QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            throw e;
        } catch (RestClientException e) {
            metrics.recordCatalogCall(label, QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            // Includes the timeouts configured above: a catalog that hangs
            // now surfaces as 503 after readTimeout instead of parking the
            // request thread indefinitely.
            log.warn("Catalog call {} failed: {}", label, e.getMessage());
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                    "El catálogo de sso-admin no está disponible", e);
        }
    }

    /**
     * sso-admin answers 403 both for an unknown uuid and for a caller with
     * no role bound to it, so the text covers both without saying which —
     * telling an unauthorized caller "it exists" is exactly the information
     * the catalog withholds.
     */
    private static String refusalMessage(HttpStatusCode status) {
        return switch (status.value()) {
            case 401 -> "Sesión inválida o expirada; vuelve a iniciar sesión";
            case 403, 404 -> "No tienes acceso a esta consulta, o no existe";
            default -> "El catálogo rechazó la consulta (" + status.value() + ")";
        };
    }

    private void requireInternalToken(String what) {
        if (internalToken == null || internalToken.isBlank()) {
            log.warn("{} called but internal token is not configured", what);
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                    "query.catalog.internal-token is not configured on this instance");
        }
    }

    private static <T> List<T> asList(T[] arr) {
        return arr == null ? List.of() : Arrays.asList(arr);
    }
}
