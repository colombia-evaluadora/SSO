package com.co.eurekatic.query.web.query;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.web.QueryRequest;
import io.github.resilience4j.ratelimiter.RateLimiter;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;
import java.util.Map;

/**
 * Read-path endpoints. Three paths, same body shape, same
 * flow:
 *
 * <ul>
 *   <li>{@code POST /query} — the basic read. Returns rows
 *       as a flat list. Legacy admin UI hits this for
 *       ad-hoc selects.</li>
 *   <li>{@code POST /service} — legacy alias used by the
 *       desktop UI to avoid clashing with the Spring MVC
 *       {@code /query} route. Behaviorally identical to
 *       {@code /query}.</li>
 *   <li>{@code POST /serviceFit} — accepts {@code limit}
 *       and {@code offset} in the body for pagination, and
 *       returns an envelope
 *       ({@code { rows, total }}) instead of a bare list.
 *       The {@code total} count is best-effort: we run the
 *       same query with a {@code COUNT(*)} wrap if the
 *       catalog SQL ends in {@code WHERE ...}; otherwise
 *       we just count the page.</li>
 * </ul>
 *
 * <p>All three require an authenticated principal (the
 * JWT). Per-row authorization happens inside the catalog.
 *
 * <p><b>V29 / V28:</b> caller identity (userId, email, roles)
 * is read by {@link QueryService#execute} directly from the
 * SecurityContextHolder (populated by JwtAuthenticationFilter),
 * NOT from the request body. There is nothing to inject here.
 */
@RestController
public class QueryController {

    private static final Logger log = LoggerFactory.getLogger(QueryController.class);

    private final QueryService service;
    private final QueryResilience resilience;

    public QueryController(QueryService service, QueryResilience resilience) {
        this.service = service;
        this.resilience = resilience;
    }

    @PostMapping("/query")
    public List<Map<String, Object>> query(@Valid @RequestBody QueryRequest req) {
        // V31 — SELECT / FUNCTION keep the legacy bare-list
        // shape so the wire is unchanged for every existing
        // client. PROCEDURE rows with OUT params also use
        // this shape; the OUT values are dropped because
        // the legacy /query endpoint never advertised them.
        // Callers that need OUT params use /serviceFit or
        // the path-dispatch controller.
        enforceRateLimit();
        return QueryResultEnvelope.rowsOnly(service.execute(req, false));
    }

    @PostMapping("/service")
    public List<Map<String, Object>> service(@Valid @RequestBody QueryRequest req) {
        enforceRateLimit();
        return QueryResultEnvelope.rowsOnly(service.execute(req, false));
    }

    /**
     * Paginated variant. The body is the same {@code uuid +
     * params + limit + offset}; the response is wrapped so
     * the caller knows the row count. V31: also carries
     * {@code outParams} when the catalog row declared them.
     */
    @PostMapping("/serviceFit")
    public Map<String, Object> serviceFit(@Valid @RequestBody QueryRequest req) {
        enforceRateLimit();
        var result = service.execute(req, false);
        Map<String, Object> body = QueryResultEnvelope.withOutParams(result);
        body.put("total", result.rows().size());
        body.put("uuid", req.uuid());
        return body;
    }

    /**
     * V33 — per-principal RPS cap. The limiter is keyed by
     * the JWT subject (email), so a noisy client can't
     * starve a quiet one. Anonymous (public) traffic falls
     * back to a fixed {@code "anonymous"} bucket so the
     * limit still applies — just shared across all
     * anonymous callers.
     *
     * <p>On reject: throws 429 with a {@code Retry-After}
     * hint. The {@code GlobalExceptionHandler} maps
     * {@link RequestNotPermitted} → 429 with the right
     * header.
     */
    private void enforceRateLimit() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        String key = (auth != null && auth.getPrincipal() instanceof AuthPrincipal p)
                ? p.email()
                : "anonymous";
        RateLimiter rl = resilience.rateLimiterFor(key);
        if (!rl.acquirePermission()) {
            log.warn("Rate limit exceeded for principal={}", key);
            throw RequestNotPermitted.createRequestNotPermitted(rl);
        }
    }
}
