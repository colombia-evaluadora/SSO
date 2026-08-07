package com.co.eurekatic.ssoadmin.controller.internal;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.QueryRepository;
import com.co.eurekatic.ssoadmin.dto.QueryDefinition;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * V27 — internal route table feed for {@code api-gateway}.
 *
 * <p>Polled every ~30s by the gateway's
 * {@code CatalogRoutesRefresher}; the response drives the
 * Spring Cloud Gateway dynamic route table so newly created
 * {@code kind=QUERY} microservices (with their
 * {@code REQUEST_URI} prefix) become routable without a
 * gateway restart.
 *
 * <p><b>NOT a public endpoint.</b> Marked {@code permitAll}
 * here only because Spring Security would otherwise try to
 * enforce the {@code SsoAdminAccessManager} chain
 * (app + endpoint binding), which doesn't apply to the
 * gateway itself. Trust boundary is the docker network:
 * only the api-gateway container can reach sso-admin, and
 * the docker-compose isolates the stack. A future hardening
 * pass can add a shared-secret header check ({@code X-Internal-Token}).
 *
 * <p>Wire format:
 * <pre>
 *   GET /internal/gateway/routes →
 *   [
 *     { "serviceId": "query-service-eval-col", "requestUri": "/api/eval-col/**",
 *       "kind": "QUERY", "stripPrefix": 2 },
 *     { "serviceId": "sso-admin",              "requestUri": "/sso-admin/**",
 *       "kind": "REST",  "stripPrefix": 1 },
 *     …
 *   ]
 * </pre>
 *
 * <p>{@code stripPrefix} is computed from the requestUri's
 * path-segment count (Spring Cloud Gateway's
 * {@code StripPrefix=N} filter strips the first N
 * path segments before forwarding). For
 * {@code "/api/eval-col/**"} → 2; for {@code "/sso-admin/**"} → 1.
 * The trailing {@code /**} is required so the gateway
 * matches concrete URLs like {@code /api/eval-col/x}.
 */
@RestController
@RequestMapping("/internal")
public class InternalGatewayController {

    private final MicroserviceRepository microserviceRepo;
    private final QueryRepository queryRepo;

    public InternalGatewayController(MicroserviceRepository microserviceRepo,
                                      QueryRepository queryRepo) {
        this.microserviceRepo = microserviceRepo;
        this.queryRepo = queryRepo;
    }

    /* ====================== route table for api-gateway ====================== */

    @GetMapping("/gateway/routes")
    public List<GatewayRoute> listRoutes() {
        return microserviceRepo.findAllByRequestUriIsNotNull().stream()
                .map(InternalGatewayController::toRoute)
                .toList();
    }

    private static GatewayRoute toRoute(Microservice m) {
        return new GatewayRoute(
                m.getId(),
                eurekaServiceId(m),
                m.getRequestUri(),
                m.getKind(),
                stripPrefixFrom(m.getRequestUri()));
    }

    /**
     * The id the gateway can actually resolve through Eureka.
     *
     * <p>For {@code kind=REST} rows the catalog's
     * {@code service_id} already IS the Eureka id
     * ({@code sso-admin}, {@code auth-center}), so it passes
     * through unchanged.
     *
     * <p>For {@code kind=QUERY} rows it does not: the catalog
     * stores the operator-facing name ({@code eval-col}) while
     * the provisioner registers the container as
     * {@code query-service-eval-col} (see
     * {@code ProvisionerController} and
     * {@code MicroserviceController#containerName}, which use
     * the same {@code "query-service-" + instanceName} rule).
     * Emitting the bare name made the gateway build
     * {@code lb://eval-col}, which no Eureka instance answers —
     * every {@code /api/eval-col/**} request 404'd. We apply
     * the same suffix rule here so the two sides agree.
     *
     * <p>Falls back to {@code dialect} when {@code instanceName}
     * is null (pre-V32 rows were named after their dialect), and
     * to the raw {@code service_id} when both are missing or the
     * id already carries the prefix — an operator who typed the
     * full {@code query-service-foo} into the catalog gets what
     * they typed, not {@code query-service-query-service-foo}.
     */
    static String eurekaServiceId(Microservice m) {
        if (!"QUERY".equalsIgnoreCase(m.getKind())) {
            return m.getServiceId();
        }
        String suffix = m.getInstanceName() != null && !m.getInstanceName().isBlank()
                ? m.getInstanceName()
                : m.getDialect();
        if (suffix == null || suffix.isBlank()) {
            return m.getServiceId();
        }
        // Idempotent: an operator who typed the full Eureka
        // name into instance_name / dialect gets it back
        // unchanged rather than query-service-query-service-foo.
        return suffix.startsWith("query-service-")
                ? suffix
                : "query-service-" + suffix;
    }

    /* ====================== path-template registry for query-service ====================== */

    /**
     * V30 — every query row with a non-null {@code path_template},
     * optionally filtered by {@code microserviceId}.
     *
     * <p>This is the internal endpoint consumed by
     * {@code query-service}'s in-memory
     * {@code com.co.eurekatic.query.routing.QueryPathRegistry}.
     * It is gated by the {@code X-Internal-Token} header (via
     * {@link com.co.eurekatic.ssoadmin.security.InternalTokenFilter})
     * rather than by per-row role auth, because:
     * <ol>
     *   <li>The registry is acting on behalf of itself, not a
     *       specific user — there's no "user" to authorize.</li>
     *   <li>Per-request auth still happens downstream, when a
     *       user calls the path-template endpoint and
     *       {@code query-service} forwards the user's JWT to
     *       {@code /getQuery}. The internal endpoint just needs
     *       to enumerate templates; the catalog per-row filter
     *       still applies at execution time.</li>
     *   <li>Synthetic users with elevated roles are a footgun —
     *       they leak across the rest of the system.</li>
     * </ol>
     *
     * <p>Result shape matches {@code QueryDefinition} exactly so
     * {@code CatalogClient.fetchPathTemplates} can deserialize
     * with the same record on the query-service side.
     */
    @Transactional(readOnly = true)
    @GetMapping("/pathTemplates")
    public List<QueryDefinition> listPathTemplates(
            @RequestParam(name = "microserviceId", required = false) Long microserviceId) {
        List<Query> rows = (microserviceId == null)
                ? queryRepo.findAllByPathTemplateIsNotNull()
                : queryRepo.findAllByMicroservice_IdAndPathTemplateIsNotNull(microserviceId);
        return rows.stream().map(QueryDefinition::fromEntity).toList();
    }

    /* ====================== whoami for query-service auto-discovery ====================== */

    /**
     * V32 — query-service calls this at boot with its own
     * instance name (passed by the provisioner as
     * {@code QUERY_INSTANCE_NAME}) to discover the
     * microservice_id it should scope its path-template
     * registry to. Before V32 the registry used
     * {@code microserviceId=null} (every template) which
     * worked because path uniqueness is per-microservice, but
     * produced a slightly wasteful registry.
     *
     * <p>Lookup precedence:
     * <ol>
     *   <li>By {@code instance_name} (the canonical field
     *       set by the provisioner — matches the
     *       {@code query-service-<instance_name>} service
     *       id Eureka sees).</li>
     *   <li>By {@code service_id} (legacy: the
     *       {@code query-service-postgres} form, or any other
     *       operator-assigned service id).</li>
     * </ol>
     *
     * <p>If neither matches, returns an empty body with
     * {@code 200} (not 404) so a query-service instance with
     * no associated microservice row degrades gracefully to
     * "global" (the registry stays empty rather than throwing).
     *
     * <p>The wire format is intentionally tiny — just the
     * fields the caller needs to populate its registry.
     */
    @Transactional(readOnly = true)
    @GetMapping("/whoami")
    public java.util.Map<String, Object> whoami(
            @RequestParam("instanceName") String instanceName) {
        java.util.Optional<Microservice> match =
                microserviceRepo.findByInstanceName(instanceName);
        if (match.isEmpty()) {
            // Fall back to service-id-based lookup. Many
            // operators set the catalog's serviceId to the
            // same string the provisioner uses as instanceName,
            // so this covers the common "I gave them the same
            // name" case.
            match = microserviceRepo.findByServiceId("query-service-" + instanceName);
        }
        if (match.isEmpty()) {
            // Empty body, 200 — caller treats this as "global".
            return java.util.Map.of();
        }
        Microservice m = match.get();
        java.util.Map<String, Object> body = new java.util.LinkedHashMap<>();
        body.put("microserviceId", m.getId());
        body.put("serviceId", m.getServiceId());
        body.put("kind", m.getKind());
        body.put("instanceName", m.getInstanceName());
        return body;
    }

    /**
     * Counts path segments in the requestUri BEFORE the
     * wildcard. Examples:
     * <ul>
     *   <li>{@code "/sso-admin/**"} → 1 (one segment before /**)</li>
     *   <li>{@code "/api/eval-col/**"} → 2</li>
     *   <li>{@code "/qs/**"} → 1</li>
     *   <li>{@code "/**"} → 0 (rarely used; matches the root)</li>
     * </ul>
     * Returns at least 1 when the prefix doesn't end with
     * {@code /**}, since at minimum the gateway has to
     * strip one segment to land on a controller path.
     */
    static int stripPrefixFrom(String requestUri) {
        if (requestUri == null) return 0;
        // Strip the trailing /** (if present) and the leading /,
        // then split on '/' and count non-empty segments.
        String core = requestUri;
        if (core.endsWith("/**")) {
            core = core.substring(0, core.length() - 3);
        } else if (core.endsWith("/*")) {
            core = core.substring(0, core.length() - 2);
        }
        if (core.startsWith("/")) {
            core = core.substring(1);
        }
        if (core.isEmpty()) return 0;
        int count = 1;
        for (int i = 0; i < core.length(); i++) {
            if (core.charAt(i) == '/') count++;
        }
        return Math.max(1, count);
    }

    /**
     * Wire record. Field names are the exact JSON keys the
     * api-gateway {@code CatalogRoutesRefresher} expects.
     */
    public record GatewayRoute(
            Long id,
            String serviceId,
            String requestUri,
            String kind,
            int stripPrefix
    ) {}
}
