package com.co.eurekatic.query.read;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.exception.PostgresErrorMapper;
import com.co.eurekatic.query.observability.QueryMetrics;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.web.QueryRequest;
import io.github.resilience4j.bulkhead.BulkheadFullException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.sql.SQLException;

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
    private final QueryMetrics metrics;
    private final QueryResilience resilience;

    public QueryService(CatalogClient catalog, JdbcTemplateRegistry registry,
                         QueryMetrics metrics, QueryResilience resilience) {
        this.catalog = catalog;
        this.registry = registry;
        this.metrics = metrics;
        this.resilience = resilience;
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
    public QueryResult execute(QueryRequest req, boolean publicOk) {
        long start = System.nanoTime();
        // Default to SELECT so the FAILURE path records
        // a meaningful mode even when the catalog row
        // couldn't be fetched (e.g. 404 before we know the
        // real mode). Real mode is overwritten below.
        String mode = "SELECT";
        try {
            QueryResult result = doExecute(req, publicOk, m -> mode = m);
            metrics.recordExecution(mode, QueryMetrics.Outcome.SUCCESS,
                    System.nanoTime() - start);
            return result;
        } catch (BulkheadFullException bfe) {
            // V33 — a slow query on this dialect has filled
            // the bulkhead (concurrent cap + queue full).
            // Surface as 503 with Retry-After so the client
            // backs off instead of retrying immediately.
            metrics.recordExecution(mode, QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            log.warn("Bulkhead full for query uuid={} (dialect={})", req.uuid(),
                    bfe.getMessage());
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                    "Service busy, retry shortly");
        } catch (RuntimeException e) {
            metrics.recordExecution(mode, QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            throw e;
        }
    }

    /**
     * The actual query pipeline. Wrapped by {@link #execute} for
     * metrics — keeps the happy-path code free of try/finally noise.
     * Uses the {@code modeSink} consumer to publish the resolved
     * execution mode back to the caller so the SUCCESS/FAILURE
     * metric carries the right tag.
     */
    private QueryResult doExecute(QueryRequest req, boolean publicOk,
                                 java.util.function.Consumer<String> modeSink) {

        Authentication auth = currentAuthentication();
        // Public path: forward whatever token we have (or
        // empty string for anonymous) to the catalog. The
        // catalog uses the principal's roles for its
        // per-uuid role check; anonymous has no roles so
        // only publicEnd=true queries survive.
        String bearer = auth == null ? "" : bearerToken(auth);
        QueryDefinition def = catalog.fetchQuery(bearer, req.uuid());

        // V28 — execution mode dispatch. The legacy SELECT
        // guard still applies for SELECT-mode rows. For
        // PROCEDURE / FUNCTION we trust the catalog author
        // (ADMIN-gated) and rely on the JDBC driver to
        // execute the CALL or SELECT * FROM func().
        // The catalog-write side (QueryAdminService) already
        // validates the SQL prefix matches the mode at
        // save time — defense in depth here is intentional.
        String mode = def.executionMode() == null
                ? "SELECT"
                : def.executionMode().trim().toUpperCase();
        modeSink.accept(mode);
        if ("SELECT".equals(mode) || "FUNCTION".equals(mode)) {
            // SELECT and FUNCTION share the same prefix
            // (FUNCTION is called as "SELECT * FROM func()").
            rejectIfMutating(def.query());
        } else if (!"PROCEDURE".equals(mode)) {
            // Unknown mode — fail closed.
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Unknown executionMode: " + def.executionMode());
        }

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
                    "La consulta no es pública");
        }

        NamedParameterJdbcTemplate jdbc = registry.resolve(def.type());

        MapSqlParameterSource params = new MapSqlParameterSource(req.params());

        // V29 — caller context injection. Pulled from the JWT
        // (AuthPrincipal.uid), NOT from the request body: the
        // client can't forge its own userId because the JWT is
        // HS256-signed with a key only auth-center knows.
        //
        // The catalog author can write SQL like
        //   CALL get_x(:caller_user_id, :caller_email)
        // and the procedure receives the verified identity.
        //
        // Both params are optional: tokens minted before V29
        // don't carry the uid claim, and the public endpoint
        // is unauthenticated (no principal at all). In either
        // case we DON'T add the named param — the procedure
        // author is responsible for handling the missing case
        // (e.g. "IF caller_user_id IS NULL THEN RAISE EXCEPTION
        // 'unauthenticated'").
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal p) {
            if (p.userId() != null) {
                params.addValue("caller_user_id", p.userId());
            }
            if (p.email() != null) {
                params.addValue("caller_email", p.email());
            }
            // V28 — caller roles injection. Two flavors so the
            // procedure author can pick the convenient one:
            //   :caller_roles        → "ADMIN,EVALUADOR"  (PL/pgSQL LIKE-friendly)
            //   :caller_roles_array  → "{ADMIN,EVALUADOR}" (PostgreSQL text[] for ANY())
            String rolesCsv = p.roles() == null || p.roles().isEmpty()
                    ? ""
                    : String.join(",", p.roles());
            String rolesArray = "{"
                    + (p.roles() == null || p.roles().isEmpty()
                        ? ""
                        : String.join(",", p.roles()))
                    + "}";
            params.addValue("caller_roles", rolesCsv);
            params.addValue("caller_roles_array", rolesArray);
        }

        if (req.limit() != null) {
            params.addValue("limit", req.limit());
        }
        if (req.offset() != null) {
            params.addValue("offset", req.offset());
        }

        // V28 — LIMIT/OFFSET only on SELECT / FUNCTION.
        // Stored procedures don't accept LIMIT/OFFSET clauses;
        // ignoring the request body's pagination is the
        // documented behavior.
        String sql = def.query();
        if ("SELECT".equals(mode) || "FUNCTION".equals(mode)) {
            if (req.limit() != null) {
                sql = sql + " LIMIT :limit";
            }
            if (req.offset() != null) {
                sql = sql + " OFFSET :offset";
            }
        }

        // V33 — wrap the JDBC execution in a per-dialect
        // bulkhead. tryAcquirePermission() returns false
        // immediately when the bulkhead + queue is full
        // (we don't wait — fail fast is the right answer
        // for a sync MVC controller; the catch in execute()
        // maps the false to a 503 Retry-After). The bulkhead
        // is registered as a Micrometer gauge by
        // QueryResilience.
        var bulkhead = resilience.bulkheadFor(def.type() == null
                ? "default" : def.type());
        if (!bulkhead.tryAcquirePermission()) {
            throw BulkheadFullException.createBulkheadFullException(bulkhead);
        }
        try {
            // V31 — PROCEDURE-mode row with declared OUT params
            // switches to CallableStatement so we can read the
            // OUT values back. Without OUT params we keep the
            // JdbcTemplate.query path (cheaper — no register-out
            // ceremony for the common case).
            boolean useCallable = "PROCEDURE".equals(mode)
                    && def.outParamNames() != null
                    && !def.outParamNames().isBlank();
            try {
                if (useCallable) {
                    log.debug("uuid={} using CallableStatement (outParams={})",
                            req.uuid(), def.outParamNames());
                    List<String> outNames = parseOutNames(def.outParamNames());
                    Map<String, Object> outValues = executeCallable(jdbc, sql, params, outNames);
                    // For procedures that ALSO return rows via RETURN QUERY,
                    // we still capture the result set. The driver returns
                    // it after the call completes.
                    List<Map<String, Object>> rows = jdbc.query(sql, params,
                            QueryService::mapRow);
                    log.debug("uuid={} returned {} rows + {} OUT params (mode={})",
                            req.uuid(), rows.size(), outValues.size(), mode);
                    return QueryResult.withOutParams(rows, outValues);
                }

                // SELECT / FUNCTION / PROCEDURE-without-OUT path.
                List<Map<String, Object>> rows = jdbc.query(sql, params,
                        QueryService::mapRow);

                log.debug("uuid={} returned {} rows (mode={})", req.uuid(), rows.size(), mode);
                // Metrics are recorded by the wrapping execute()
                // method — keeps the mode tag accurate (FAILURE
                // records the mode we resolved before throwing).
                return QueryResult.rowsOnly(rows);
            } catch (DataAccessException dae) {
                // V32 — unwrap Spring's DataAccessException to
                // the underlying SQLException and translate via
                // PostgresErrorMapper. The original exception
                // type is preserved as the cause for log forensics.
                SQLException sqlEx = dae.getMostSpecificCause() instanceof SQLException
                        ? (SQLException) dae.getMostSpecificCause()
                        : null;
                if (sqlEx != null) {
                    throw PostgresErrorMapper.map(sqlEx);
                }
                throw dae;  // bubble un-translated so the catch-all 500 still triggers
            }
        } finally {
            // Always release — including on PostgresErrorMapper
            // throws (the mapped ResponseStatusException is a
            // RuntimeException so the throw above short-circuits,
            // and this finally still runs).
            bulkhead.onComplete();
        }
    }

    /**
     * Single-row mapper extracted for reuse between the
     * legacy JdbcTemplate.query path and the CallableStatement
     * path. LinkedHashMap preserves the column order from
     * the ResultSetMetaData — the legacy UI depends on it
     * for tabular rendering.
     */
    private static Map<String, Object> mapRow(java.sql.ResultSet rs, int rn)
            throws java.sql.SQLException {
        java.sql.ResultSetMetaData md = rs.getMetaData();
        int cols = md.getColumnCount();
        Map<String, Object> row = new LinkedHashMap<>(cols);
        for (int i = 1; i <= cols; i++) {
            row.put(md.getColumnLabel(i), rs.getObject(i));
        }
        return row;
    }

    /**
     * V31 — execute a PROCEDURE-mode row that declares OUT
     * params via {@link QueryDefinition#outParamNames()}. The
     * procedure runs once; OUT values are read into a
     * {@code Map<String, Object>} keyed by the bare param
     * name (without the leading {@code ":"}).
     *
     * <p>Why {@code Types.OTHER}: PostgreSQL's JDBC driver
     * lets us register the OUT as OTHER and read it back as
     * {@code Object}, which avoids the "pick the right SQL
     * type" guesswork (the catalog author knows best, and
     * OTHER + getObject(i) lets the driver serialize any
     * PG type back to its Java representation). For known
     * scalar types (VARCHAR, BIGINT, BOOLEAN) this works
     * seamlessly; for composite / cursor types we'd need
     * CallableStatement.getObject(name, Class<T>) which is
     * out of scope for v1.
     */
    private Map<String, Object> executeCallable(NamedParameterJdbcTemplate jdbc,
                                                 String sql,
                                                 MapSqlParameterSource params,
                                                 List<String> outNames) {
        return jdbc.getJdbcTemplate().execute(
                (java.sql.Connection con) -> {
                    try (java.sql.CallableStatement cs = con.prepareCall(sql)) {
                        // Bind IN params (and any INOUT).
                        params.forEach((name, value) -> {
                            try {
                                cs.setObject(name, value);
                            } catch (java.sql.SQLException e) {
                                throw new IllegalStateException(
                                        "Failed to bind param " + name, e);
                            }
                        });
                        // Register OUT params. The PG driver
                        // accepts Types.OTHER for any type and
                        // returns the value via getObject().
                        for (String outName : outNames) {
                            cs.registerOutParameter(outName,
                                    java.sql.Types.OTHER);
                        }
                        cs.execute();
                        // Read OUT values.
                        Map<String, Object> out = new LinkedHashMap<>();
                        for (String outName : outNames) {
                            out.put(outName, cs.getObject(outName));
                        }
                        return out;
                    }
                });
    }

    /**
     * Parse the comma-separated OUT param names into a
     * trimmed, non-empty list. Tolerant of whitespace
     * ("out_a , out_b" → ["out_a", "out_b"]).
     */
    private static List<String> parseOutNames(String csv) {
        return java.util.Arrays.stream(csv.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .collect(java.util.stream.Collectors.toList());
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
                    "La consulta debe ser un SELECT o un WITH; se recibió: " + first);
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
                    "Falta el token bearer en el contexto de seguridad");
        }
        return s;
    }
}