package com.co.eurekatic.query.web.path;

import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.routing.QueryPathRegistry;
import com.co.eurekatic.query.web.QueryRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * V27 — path-based query dispatcher.
 *
 * <p>The api-gateway strips the per-microservice
 * {@code REQUEST_URI} prefix (e.g. {@code /api/eval-col})
 * before forwarding, so requests arrive here as
 * {@code POST /<pathTemplate>}. Examples:
 * <ul>
 *   <li>{@code POST /api/eval-col/establecimiento/42}
 *       → forward → {@code POST /establecimiento/42}</li>
 *   <li>{@code POST /api/eval-col/users?active=true}
 *       → forward → {@code POST /users?active=true}</li>
 * </ul>
 *
 * <p>This controller catches any {@code POST /<anything>}
 * (other than the reserved legacy paths {@code /query},
 * {@code /service}, {@code /serviceFit},
 * {@code /public/service}, {@code /write}) and resolves
 * the request URI against {@link QueryPathRegistry}'s
 * {@code Map<pathTemplate, uuid>}. A 404 is returned when
 * no template matches — that path simply doesn't exist in
 * the catalog.
 *
 * <p><b>Query params and body</b> are forwarded exactly
 * the way the legacy {@code /query} controller expects:
 * path variables from the template land in the params map
 * under their template names ({@code :id → params.id});
 * request query parameters ride alongside; the JSON body
 * (if any) is flattened one level so a request like
 * {@code {"filtros":{"regional":"x"}}} becomes
 * {@code filtros_regional=x} (procedures can use
 * {@code :filtros_regional} in the catalog SQL).
 *
 * <p><b>Caller context</b> (V29/V28 — userId, email, roles)
 * is injected by {@link QueryService#execute} directly from
 * the SecurityContextHolder, exactly like the legacy
 * {@code /query} controller. Nothing on the request wire.
 */
@RestController
public class QueryPathController {

    private final QueryService service;
    private final QueryPathRegistry registry;

    public QueryPathController(QueryService service, QueryPathRegistry registry) {
        this.service = service;
        this.registry = registry;
    }

    /**
     * Catch-all POST handler. Spring's path matching picks
     * the more specific {@code /query}, {@code /service},
     * etc. mappings first; this one only fires for paths
     * the legacy controllers don't claim.
     */
    @PostMapping("/**")
    public Map<String, Object> dispatch(
            jakarta.servlet.http.HttpServletRequest request,
            @RequestParam Map<String, String> queryParams,
            @RequestBody(required = false) Map<String, Object> body) {

        String fullPath = (String) request.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        // Spring sometimes includes a trailing slash or
        // an empty path for the bare "/" mapping; normalize.
        if (fullPath == null || fullPath.isEmpty()) {
            fullPath = "/";
        }

        var match = registry.match(fullPath).orElseThrow(() ->
                new ResponseStatusException(HttpStatus.NOT_FOUND,
                        "No query registered for path: " + fullPath));

        Map<String, Object> params = new LinkedHashMap<>();
        // Precedence: path vars → query params → body
        // (flattened). Same flattening rule as the legacy
        // service execute(); a procedure author can read
        // any of them under its expected name.
        params.putAll(match.pathVars());
        params.putAll(queryParams);
        if (body != null) {
            params.putAll(flatten(body, ""));
        }

        QueryRequest qr = new QueryRequest(
                match.uuid(),
                params,
                /* limit  */ null,
                /* offset */ null);
        // publicOk=false: path-based queries are not
        // anonymous endpoints. A procedure author who
        // wants anonymous access should set publicEnd=true
        // AND mark the query without a role binding — same
        // gate as /query, just with a different URL.
        //
        // V31 — path-dispatch always uses the envelope
        // shape ({rows, outParams}) so callers can rely
        // on the same JSON shape regardless of mode.
        return com.co.eurekatic.query.web.query.QueryResultEnvelope
                .withOutParams(service.execute(qr, false));
    }

    /**
     * Flatten a nested map one level deep. Keys are joined
     * with {@code _}. Used to translate the JSON body
     * ({@code {"filtros":{"regional":"x"}}}) into flat
     * named params ({@code filtros_regional=x}) so JDBC
     * {@code MapSqlParameterSource} can bind them via
     * {@code :filtros_regional}. Nested maps deeper than
     * one level are skipped (their keys are dropped with a
     * WARN) — the procedure author should keep payloads
     * shallow.
     */
    private static Map<String, Object> flatten(Map<String, Object> body, String prefix) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (var e : body.entrySet()) {
            String key = prefix.isEmpty() ? e.getKey() : prefix + "_" + e.getKey();
            Object val = e.getValue();
            if (val instanceof Map<?, ?> nested) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) nested;
                out.putAll(flatten(nestedMap, key));
            } else {
                out.put(key, val);
            }
        }
        return out;
    }
}
