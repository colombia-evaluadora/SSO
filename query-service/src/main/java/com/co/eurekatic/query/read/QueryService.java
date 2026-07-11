package com.co.eurekatic.query.read;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.web.QueryRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Read-path business logic. The flow:
 *
 * <ol>
 *   <li>Forward the caller's bearer token to sso-admin's
 *       {@code /getQuery} to resolve the uuid. Authorization
 *       happens there (per-row role intersection).</li>
 *   <li>Look up the {@link NamedParameterJdbcTemplate} for
 *       the catalog row's {@code TYPE} column.</li>
 *   <li>Bind the request params (plus any auto-derived
 *       placeholders) and execute the SQL.</li>
 *   <li>Map the result set to a {@code List<Map<String,Object>>}
 *       — the same shape the legacy returned.</li>
 * </ol>
 *
 * <p><b>Anti-patterns this class deliberately avoids</b>
 * (from the spec):
 * <ul>
 *   <li>No table or column names from the request — only
 *       the uuid is accepted.</li>
 *   <li>No SQL string concatenation of identifiers — the
 *       SQL itself comes verbatim from the catalog.</li>
 *   <li>No DDL generation — only SELECTs are allowed; an
 *       INSERT/UPDATE/DELETE in the catalog SQL throws.</li>
 * </ul>
 */
@Service
public class QueryService {

    private static final Logger log = LoggerFactory.getLogger(QueryService.class);

    private final CatalogClient catalog;
    private final JdbcTemplateRegistry registry;

    public QueryService(CatalogClient catalog, JdbcTemplateRegistry registry) {
        this.catalog = catalog;
        this.registry = registry;
    }

    /**
     * Resolves a uuid and runs the underlying SELECT.
     *
     * @param req       the request body with uuid and params.
     * @param publicOk  if {@code true}, allow queries marked
     *                  {@code publicEnd}. If {@code false}
     *                  (the {@code /query}, {@code /service},
     *                  {@code /serviceFit} paths), a query
     *                  marked public is still permitted — the
     *                  publicEnd flag widens access, it
     *                  doesn't restrict it. So this flag is
     *                  effectively informational; we keep it
     *                  for symmetry with the
     *                  {@code /public/service} path which
     *                  calls this method with {@code true}.
     * @return rows.
     */
    public List<Map<String, Object>> execute(QueryRequest req, boolean publicOk) {
        Authentication auth = currentAuthentication();
        // Public path: forward whatever token we have (or
        // empty string for anonymous) to the catalog. The
        // catalog uses the principal's roles for its
        // per-uuid role check; anonymous has no roles so
        // only publicEnd=true queries survive.
        String bearer = auth == null ? "" : bearerToken(auth);
        QueryDefinition def = catalog.fetchQuery(bearer, req.uuid());

        // Sanity-check the SQL. Catalog authors can't be
        // trusted to write only SELECTs — we explicitly
        // reject any DDL/DML keywords at the start of the
        // query (after stripping leading whitespace and
        // comments). This is defense-in-depth: even if the
        // admin UI is compromised, an injected UPDATE in
        // the catalog SQL still doesn't run.
        rejectIfMutating(def.query());

        // publicEnd is advisory on the auth path; the
        // catalog already returned 403 for callers without
        // a bound role. If for some reason we got a
        // publicEnd=false row and the call came through
        // /public/service, we still let the catalog's
        // decision stand (it was based on the principal's
        // role, which is what matters).
        if (!def.publicEnd() && publicOk) {
            // The /public/service path only accepts
            // publicEnd=true queries. Non-public queries
            // should never reach here — the catalog would
            // have rejected them anyway because the
            // unauthenticated SecurityContextHolder has
            // no role. Defensive double-check.
            log.warn("Non-public query {} reached /public/service — denying", req.uuid());
            throw new ResponseStatusException(HttpStatus.FORBIDDEN,
                    "Query is not public");
        }

        NamedParameterJdbcTemplate jdbc = registry.resolve(def.type());

        MapSqlParameterSource params = new MapSqlParameterSource(req.params());
        if (req.limit() != null) {
            params.addValue("limit", req.limit());
        }
        if (req.offset() != null) {
            params.addValue("offset", req.offset());
        }

        // Pagination: append LIMIT/OFFSET to the SQL. This
        // assumes the catalog author left no trailing
        // semicolon; the catalog author is the admin UI
        // (which never emits one). We bind the values as
        // named parameters rather than concatenating the
        // numeric values to avoid any chance of SQL
        // injection — even though the limit/offset come
        // from the request body, treating them as
        // integers-only protects against `;DROP` style
        // payloads.
        String sql = def.query();
        if (req.limit() != null) {
            sql = sql + " LIMIT :limit";
        }
        if (req.offset() != null) {
            sql = sql + " OFFSET :offset";
        }

        // Result set → List<Map>. LinkedHashMap preserves
        // the column order from the ResultSetMetaData,
        // which the legacy UI depends on for tabular
        // rendering.
        List<Map<String, Object>> rows = jdbc.query(sql, params, (rs, rn) -> {
            java.sql.ResultSetMetaData md = rs.getMetaData();
            int cols = md.getColumnCount();
            Map<String, Object> row = new LinkedHashMap<>(cols);
            for (int i = 1; i <= cols; i++) {
                row.put(md.getColumnLabel(i), rs.getObject(i));
            }
            return row;
        });

        log.debug("uuid={} returned {} rows", req.uuid(), rows.size());
        return rows;
    }

    /**
     * Lightweight SQL guard. Accepts statements whose first
     * keyword (case-insensitive, after stripping leading
     * whitespace and {@code --} comments) is {@code SELECT}
     * or {@code WITH}. Everything else — INSERT, UPDATE,
     * DELETE, MERGE, CREATE, DROP, ALTER, GRANT, REVOKE,
     * TRUNCATE, CALL — is rejected.
     *
     * <p>We deliberately do NOT try to parse SQL — that's a
     * losing game for general text. We only catch the
     * obvious cases. A motivated attacker who can edit
     * catalog rows could embed a malicious SELECT that
     * reads credentials; the catalog authorization check
     * plus the admin-only CRUD endpoint are the actual
     * defenses, this is just the last-mile guard.
     */
    static void rejectIfMutating(String sql) {
        String trimmed = stripLeadingNoise(sql);
        String first = trimmed.isEmpty() ? "" : trimmed.split("\\s+", 2)[0].toUpperCase();
        if (!first.equals("SELECT") && !first.equals("WITH")) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Query must be a SELECT or WITH; got: " + first);
        }
    }

    private static String stripLeadingNoise(String sql) {
        String s = sql.stripLeading();
        // Strip leading single-line comments so a query
        // starting with "-- foo\nSELECT ..." is accepted.
        while (s.startsWith("--")) {
            int nl = s.indexOf('\n');
            if (nl < 0) return "";
            s = s.substring(nl + 1).stripLeading();
        }
        return s;
    }

    private static Authentication currentAuthentication() {
        // For the public path, anonymous is allowed (the
        // catalog will reject non-publicEnd queries). For
        // everything else, Spring Security has already
        // returned 403 by the time we get here because
        // .anyRequest().authenticated() applies.
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal) {
            return auth;
        }
        // Anonymous or no authentication — caller decides
        // whether to accept.
        return null;
    }

    /**
     * Extracts the bearer token that
     * {@link com.co.eurekatic.query.security.JwtAuthenticationFilter}
     * stored as the {@link Authentication#getCredentials()}.
     * The catalog needs the raw token to re-validate it.
     */
    private static String bearerToken(Authentication auth) {
        Object creds = auth.getCredentials();
        if (!(creds instanceof String s) || s.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "Missing bearer token in security context");
        }
        return s;
    }
}