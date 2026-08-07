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
 * (if any) is traversed and each leaf becomes a bind
 * parameter under a {@code body.}-prefixed dotted path.
 * A request like {@code {"filtros":{"regional":"x"}}}
 * becomes {@code body.filtros.regional = "x"} — the
 * catalog SQL/procedure binds it via
 * {@code :body.filtros.regional}. See {@link #flattenToPaths}
 * for the full contract.
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

        String rawPath = (String) request.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        // Spring sometimes includes a trailing slash or an empty
        // path for the bare "/" mapping; normalize. Assigned once
        // into a final local because the orElseThrow lambda below
        // captures it, and a captured local must be effectively
        // final — reassigning `fullPath` in place would not compile.
        final String fullPath = (rawPath == null || rawPath.isEmpty()) ? "/" : rawPath;

        var match = registry.match(fullPath).orElseThrow(() ->
                new ResponseStatusException(HttpStatus.NOT_FOUND,
                        "No query registered for path: " + fullPath));

        Map<String, Object> params = new LinkedHashMap<>();
        // Precedence: path vars → query params → body
        // (dotted-path flattened). Same flattening rule as the
        // legacy service execute(); a procedure author can read
        // any of them under its expected name.
        params.putAll(match.pathVars());
        params.putAll(queryParams);
        if (body != null) {
            params.putAll(flattenToPaths(body, "body"));
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
     * Traverse a JSON body and register each leaf as a bind
     * parameter with a dotted path. The {@code body} prefix
     * is reserved — the catalog SQL/procedure accesses the
     * flattened params via {@code :body.<path.to.leaf>}.
     *
     * <p>Examples:
     * <ul>
     *   <li>{@code {"filtros": {"regional": "x"}}} →
     *       {@code body.filtros.regional = "x"}</li>
     *   <li>{@code {"page": 1}} → {@code body.page = 1}</li>
     *   <li>{@code {"tags": ["a","b"]}} →
     *       {@code body.tags = ["a","b"]} (arrays kept as-is;
     *       JDBC binds the list to the parameter)</li>
     * </ul>
     *
     * <p>Why dots and not underscores? Two reasons:
     * <ol>
     *   <li><b>Property-access reads naturally</b> — the
     *       SQL mirrors the JSON shape: {@code WHERE
     *       regional = :body.filtros.regional} reads like
     *       {@code row.filtros.regional}.</li>
     *   <li><b>No name collisions</b> — underscore
     *       flattening ({@code filtros_regional} vs
     *       {@code filtros_regional_id}) creates ambiguous
     *       bind names; dotted paths don't collide when
     *       branches diverge.</li>
     * </ol>
     *
     * <p>Why the {@code body} prefix? Without it, a
     * top-level field like {@code "id"} would bind as
     * {@code :id} — clashing with the path variable
     * extraction above ({@code params.putAll(match.pathVars())}
     * is the same map). The prefix keeps body-derived
     * bindings clearly separated from path/query params.
     * Reserved name: a top-level {@code "body"} field in
     * the request would bind as {@code body.body.foo} for
     * any nested {@code foo} — verbose but unambiguous.
     *
     * <p>Visibility: package-private for direct unit testing
     * by {@code QueryPathControllerTest}. Production code
     * never calls this directly.
     */
    static Map<String, Object> flattenToPaths(Map<String, Object> body, String prefix) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (var e : body.entrySet()) {
            String key = prefix + "." + e.getKey();
            Object val = e.getValue();
            if (val instanceof Map<?, ?> nested) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) nested;
                out.putAll(flattenToPaths(nestedMap, key));
            } else {
                out.put(key, val);
            }
        }
        return out;
    }
}
