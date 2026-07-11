package com.co.eurekatic.query.web.metadata;

import com.co.eurekatic.query.read.ColumnsService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Metadata endpoint backing the admin-ui Writes Catalog
 * "pick column(s)" panel. Returns one row per base column of
 * a named table, joined with the table's primary-key bit per
 * row so the frontend can pre-tick the {@code keyColumns}
 * picker on {@code UPDATE} writes.
 *
 * <p><b>URL surface.</b> Locally (inside the container) this
 * is {@code GET /columns?dialect=…&schema=…&table=…}.
 * Through the api-gateway discovery locator it surfaces as
 * {@code GET /query-service-<instanceName>/columns}, which is
 * what the admin-ui hits. {@link InstanceNameResolver} adds
 * the {@code query-service-} prefix to the
 * {@code QUERY_INSTANCE_NAME} env so
 * {@code instanceName=postgres} becomes
 * {@code /query-service-postgres/columns}.
 *
 * <p><b>Auth.</b> JWT-required via the default
 * {@code anyRequest().authenticated()} rule. The caller is
 * always an SSO admin who already authenticated against
 * {@code sso-admin}; we don't add a second role gate here.
 *
 * <p><b>Errors.</b> The service layer throws
 * {@link IllegalArgumentException} for unknown dialects,
 * missing {@code table}, or malformed identifiers; all are
 * mapped to {@code 400 BAD_REQUEST} by
 * {@code GlobalExceptionHandler}. Missing {@code schema} is
 * allowed (catalogs without schemas pass {@code null}).
 */
@RestController
public class ColumnsController {

    private final ColumnsService service;

    public ColumnsController(ColumnsService service) {
        this.service = service;
    }

    /**
     * @param dialect  the {@code queryDataSources} key.
     *                 Required. The service lowercases before
     *                 lookup.
     * @param schema   schema of the target table. Required at
     *                 the controller level so a typo doesn't
     *                 quietly fan-out to "any schema" (which
     *                 {@code DatabaseMetaData.getColumns}
     *                 otherwise supports). Identifiers only —
     *                 no {@code %} / {@code _} / {@code .}.
     * @param table    table name. Required, identifier only.
     */
    @GetMapping("/columns")
    public List<ColumnInfo> list(
            @RequestParam("dialect") String dialect,
            @RequestParam("schema") String schema,
            @RequestParam("table") String table) {
        return service.list(dialect, schema, table);
    }
}
