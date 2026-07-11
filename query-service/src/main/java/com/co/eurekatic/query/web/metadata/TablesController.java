package com.co.eurekatic.query.web.metadata;

import com.co.eurekatic.query.read.TablesService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Metadata endpoint backing the admin-ui Writes Catalog
 * "pick a table" dropdown. Returned rows are the base
 * tables ({@code new String[]{"TABLE"}}) of the
 * {@code queryDataSources} entry for the given dialect.
 *
 * <p><b>URL surface.</b> Locally (inside the container) this
 * is {@code GET /tables}. Through the api-gateway discovery
 * locator it surfaces as
 * {@code GET /query-service-<instanceName>/tables}, which is
 * the URL the admin-ui hits. {@link InstanceNameResolver}
 * adds the {@code query-service-} prefix to the
 * {@code QUERY_INSTANCE_NAME} env so
 * {@code instanceName=postgres} becomes
 * {@code /query-service-postgres/tables}.
 *
 * <p><b>Auth.</b> JWT-required via the default
 * {@code anyRequest().authenticated()} rule. The caller is
 * always an SSO admin who already authenticated against
 * {@code sso-admin}; we don't add a second role gate here.
 *
 * <p><b>Errors.</b> The service layer throws
 * {@link IllegalArgumentException} for unknown dialects and
 * malformed schema; both are mapped to {@code 400 BAD_REQUEST}
 * by {@code GlobalExceptionHandler}.
 */
@RestController
public class TablesController {

    private final TablesService service;

    public TablesController(TablesService service) {
        this.service = service;
    }

    /**
     * @param dialect the {@code queryDataSources} key. The
     *                service lowercases before lookup.
     * @param schema  optional schema filter (identifier only,
     *                no {@code %} / {@code _}).
     */
    @GetMapping("/tables")
    public List<TableInfo> list(
            @RequestParam("dialect") String dialect,
            @RequestParam(value = "schema", required = false) String schema) {
        return service.list(dialect, schema);
    }
}
