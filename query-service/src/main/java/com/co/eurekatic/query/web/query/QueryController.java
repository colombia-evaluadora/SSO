package com.co.eurekatic.query.web.query;

import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.web.QueryRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * Uuid-in-body read endpoints — the surface that pre-dates the path
 * dispatcher ({@link com.co.eurekatic.query.web.path.QueryPathController}),
 * which is where production traffic goes today.
 *
 * <ul>
 *   <li>{@code POST /query} and {@code POST /service} — the same read,
 *       under two URLs. {@code /query} is what the admin-ui's query tester
 *       calls; {@code /service} is the alias the desktop UI used to avoid
 *       clashing with its own {@code /query} route. One handler serves
 *       both: they were duplicate methods with identical bodies, and two
 *       copies of a thing is two places for it to drift.</li>
 *   <li>{@code POST /serviceFit} — same read, wrapped in the
 *       {@code {rows, outParams?}} envelope the path dispatcher also
 *       returns, so a caller that needs OUT params has a uuid-in-body
 *       route to get them.</li>
 * </ul>
 *
 * <p>All of them require an authenticated principal; per-row authorization
 * happens inside the catalog. Caller identity (userId, email, roles) is read
 * by {@link QueryService#execute} from the SecurityContextHolder, never from
 * the request body — there is nothing to inject here.
 */
@RestController
public class QueryController {

    private final QueryService service;
    private final QueryResilience resilience;

    public QueryController(QueryService service, QueryResilience resilience) {
        this.service = service;
        this.resilience = resilience;
    }

    /**
     * Bare-list shape: {@code [ {col: val}, … ]}. A PROCEDURE row with OUT
     * params is accepted here too, but its OUT values are dropped — this
     * shape has no place to put them. Use {@code /serviceFit} for those.
     */
    @PostMapping({"/query", "/service"})
    public List<Map<String, Object>> query(@Valid @RequestBody QueryRequest req) {
        resilience.enforceRateLimit();
        return QueryResultEnvelope.rowsOnly(service.execute(req, false));
    }

    /**
     * Envelope shape: {@code {rows, outParams?}} — the same body the path
     * dispatcher returns, so a consumer can move between the two without
     * re-learning the response.
     *
     * <p>{@code total} is the size of the returned page, not a count of
     * everything that matched: this endpoint runs the catalog SQL exactly
     * as written and never wraps it in a {@code COUNT(*)}. Pagination is
     * the author's to write with {@code :QUERY.SIZE} / {@code :QUERY.OFFSET},
     * which also leaves them in control of the dialect and the clause
     * order.
     */
    @PostMapping("/serviceFit")
    public Map<String, Object> serviceFit(@Valid @RequestBody QueryRequest req) {
        resilience.enforceRateLimit();
        var result = service.execute(req, false);
        Map<String, Object> body = QueryResultEnvelope.withOutParams(result);
        body.put("total", result.rows().size());
        body.put("uuid", req.uuid());
        return body;
    }
}
