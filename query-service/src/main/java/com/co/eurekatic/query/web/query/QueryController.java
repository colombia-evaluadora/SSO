package com.co.eurekatic.query.web.query;

import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.web.QueryRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

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
 */
@RestController
public class QueryController {

    private final QueryService service;

    public QueryController(QueryService service) {
        this.service = service;
    }

    @PostMapping("/query")
    public List<Map<String, Object>> query(@Valid @RequestBody QueryRequest req) {
        return service.execute(req, false);
    }

    @PostMapping("/service")
    public List<Map<String, Object>> service(@Valid @RequestBody QueryRequest req) {
        return service.execute(req, false);
    }

    /**
     * Paginated variant. The body is the same {@code uuid +
     * params + limit + offset}; the response is wrapped so
     * the caller knows the row count.
     */
    @PostMapping("/serviceFit")
    public Map<String, Object> serviceFit(@Valid @RequestBody QueryRequest req) {
        List<Map<String, Object>> rows = service.execute(req, false);
        return Map.of(
                "rows", rows,
                "total", rows.size(),
                "uuid", req.uuid());
    }
}