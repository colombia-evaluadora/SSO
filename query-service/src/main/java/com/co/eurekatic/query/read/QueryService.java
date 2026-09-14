package com.co.eurekatic.query.read;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.query.ParamBinder;
import com.co.eurekatic.common.query.ParamConstraintValidator;
import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.common.query.ParamTypes;
import com.co.eurekatic.common.query.SqlRewriter;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.exception.ParamConstraintViolationException;
import com.co.eurekatic.query.exception.PostgresErrorMapper;
import com.co.eurekatic.query.observability.QueryMetrics;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.routing.CatalogResultCacheService;
import com.co.eurekatic.query.web.QueryRequest;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.resilience4j.bulkhead.BulkheadFullException;
import org.postgresql.util.PGobject;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.springframework.web.server.ResponseStatusException;

import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * Read-path business logic. The flow:
 *
 * <ol>
 *   <li>Forward the caller's bearer token to sso-admin's
 *       {@code /getQuery} to resolve the uuid. Authorization
 *       happens there (per-row role intersection).</li>
 *   <li>Look up the {@link NamedParameterJdbcTemplate} for
 *       the catalog row's {@code TYPE} column.</li>
 *   <li>Bind the request params (plus the {@code CONTEXT.*}
 *       values derived from the JWT and the HTTP request) and
 *       execute the SQL in the row's execution mode.</li>
 *   <li>Map the result set to a {@code List<Map<String,Object>>}.</li>
 * </ol>
 *
 * <p><b>Anti-patterns this class deliberately avoids:</b>
 * <ul>
 *   <li>No table or column names from the request — only
 *       the uuid is accepted.</li>
 *   <li>No SQL string concatenation of identifiers — the
 *       SQL itself comes verbatim from the catalog.</li>
 *   <li>No DDL — SELECT/FUNCTION rows must start with SELECT or
 *       WITH; DML and PROCEDURE rows are validated by the
 *       catalog at save time.</li>
 * </ul>
 */
@Service
public class QueryService {

    private static final Logger log = LoggerFactory.getLogger(QueryService.class);

    private final CatalogClient catalog;
    private final JdbcTemplateRegistry registry;
    private final QueryMetrics metrics;
    private final QueryResilience resilience;
    private final ObjectMapper objectMapper;
    private final CatalogResultCacheService resultCache;

    public QueryService(CatalogClient catalog, JdbcTemplateRegistry registry,
                         QueryMetrics metrics, QueryResilience resilience,
                         ObjectMapper objectMapper,
                         CatalogResultCacheService resultCache) {
        this.catalog = catalog;
        this.registry = registry;
        this.metrics = metrics;
        this.resilience = resilience;
        this.objectMapper = objectMapper;
        this.resultCache = resultCache;
    }

    /**
     * Resolves a uuid and runs the underlying SQL.
     *
     * @param req       the request body with uuid and params.
     * @param publicOk  {@code true} on the {@code /public/service}
     *                  path. The catalog already refuses non-public
     *                  rows to anonymous callers; this flag is the
     *                  defensive double-check on this side.
     */
    public QueryResult execute(QueryRequest req, boolean publicOk) {
        long start = System.nanoTime();
        // Defaults so the FAILURE metric has a mode even when the
        // catalog row couldn't be fetched. doExecute overwrites them
        // once the row is resolved; single-element arrays because a
        // lambda can't assign a captured local.
        final String[] mode = { "SELECT" };
        final String[] httpMethod = { "GET" };
        final String[] pathTemplate = { null };
        try {
            QueryResult result = doExecute(req, publicOk,
                    (m, hm, pt) -> { mode[0] = m; httpMethod[0] = hm; pathTemplate[0] = pt; });
            metrics.recordExecution(mode[0], QueryMetrics.Outcome.SUCCESS,
                    System.nanoTime() - start);
            // Invalidate on the row's HTTP verb, not on execution mode:
            // a SELECT-mode row can still write ("SELECT ... FROM
            // fn_upsert_x(...)"). The verb is what the catalog author
            // committed to meaning "this mutates". The wipe is scoped
            // to the row's resource (first path segment) so a write
            // under /menus/** never evicts /roles/** cached GETs.
            if (!"GET".equalsIgnoreCase(httpMethod[0])) {
                resultCache.invalidateForResource(pathTemplate[0]);
            }
            return result;
        } catch (BulkheadFullException bfe) {
            metrics.recordExecution(mode[0], QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            log.warn("Bulkhead full for query uuid={} (dialect={})", req.uuid(),
                    bfe.getMessage());
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                    "Service busy, retry shortly");
        } catch (RuntimeException e) {
            metrics.recordExecution(mode[0], QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            throw e;
        }
    }

    /** Sink through which {@link #doExecute} publishes what it resolved about the row. */
    @FunctionalInterface
    private interface ResolvedSink {
        void accept(String mode, String httpMethod, String pathTemplate);
    }

    private QueryResult doExecute(QueryRequest req, boolean publicOk,
                                 ResolvedSink resolvedSink) {

        Authentication auth = currentAuthentication();
        // Anonymous callers forward an empty bearer: the catalog has
        // no roles to intersect, so only publicEnd=true rows survive.
        String bearer = auth == null ? "" : bearerToken(auth);
        QueryDefinition def = catalog.fetchQuery(bearer, req.uuid());

        String mode = def.executionMode() == null
                ? "SELECT"
                : def.executionMode().trim().toUpperCase();
        // Null httpMethod (legacy rows) defaults to POST — same
        // convention QueryPathRegistry#refresh applies.
        String httpMethod = def.httpMethod() == null || def.httpMethod().isBlank()
                ? "POST"
                : def.httpMethod().trim().toUpperCase();
        resolvedSink.accept(mode, httpMethod, def.pathTemplate());
        if ("SELECT".equals(mode) || "FUNCTION".equals(mode)) {
            // FUNCTION is called as "SELECT * FROM func()", so both
            // share the read-only prefix guard. DML is granted through
            // its own mode, never by relaxing this one.
            rejectIfMutating(def.query());
        } else if ("DML".equals(mode)) {
            // INSERT/UPDATE written directly. The catalog validated at
            // save time that the row is bound to POST/PUT/PATCH and
            // that the first keyword is neither DELETE nor DDL.
            log.debug("uuid={} ejecuta DML directo", req.uuid());
        } else if (!"PROCEDURE".equals(mode)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Unknown executionMode: " + def.executionMode());
        }

        if (!def.publicEnd() && publicOk) {
            log.warn("Non-public query {} reached /public/service — denying", req.uuid());
            throw new ResponseStatusException(HttpStatus.FORBIDDEN,
                    "La consulta no es pública");
        }

        NamedParameterJdbcTemplate jdbc = registry.resolve(def.type());

        // Caller params + CONTEXT.* from the JWT/request. Keys are NOT
        // re-cased here: Spring JDBC binds case-sensitively against the
        // SQL placeholders, so ParamBinder publishes aliases instead and
        // does its paramTypes lookup case-insensitively.
        Map<String, Object> allParams = new LinkedHashMap<>(
                req.params() == null ? Map.of() : req.params());
        injectContextParams(allParams, auth);

        // ClickHouse requires literal LIMIT/OFFSET (a bound parameter
        // there fails with "LIMIT expression must be constant"). For
        // clickhouse rows referencing :BODY.PAGESIZE/:BODY.PAGEOFFSET
        // this substitutes validated integers into the SQL and drops
        // the keys from allParams before anything else sees them.
        String sql = substituteClickHouseLimitOffset(def.query(), def.type(), allParams);

        // Caller-controlled keys the SQL doesn't reference and the
        // catalog doesn't declare are ignored, not rejected: a client
        // posting its whole form object must not fail because of a
        // field this query never asked for. What IS still checked:
        // a placeholder the SQL references must have a declared type
        // (otherwise Spring would bind it as VARCHAR and PG would
        // answer "function xxx(character varying, ...) does not exist"),
        // and declared-required ('!') params must be present — both
        // enforced below by the guard and by ParamBinder.
        Set<String> referenced = referencedPlaceholders(sql);
        List<String> ignored = dropUnreferencedCallerParams(allParams, referenced, def.paramTypes());
        if (!ignored.isEmpty()) {
            log.debug("uuid={} ignora parámetros no definidos: {}", req.uuid(), ignored);
        }

        if (def.paramTypes() != null) {
            List<String> untypedCallerParams = allParams.keySet().stream()
                    .filter(k -> {
                        String ns = namespaceOf(k);
                        return ParamNamespace.PARAM.equals(ns) || ParamNamespace.BODY.equals(ns);
                    })
                    .filter(k -> !isDeclared(k, def.paramTypes()))
                    .sorted()
                    .toList();
            if (!untypedCallerParams.isEmpty()) {
                log.warn("uuid={} tiene placeholders caller-controlled sin tipo declarado: {} "
                        + "(paramTypes={}). El autor debe editar la fila en el catálogo.",
                        req.uuid(), untypedCallerParams, def.paramTypes());
                throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                        "El query " + req.uuid() + " tiene placeholders sin tipo declarado: "
                        + untypedCallerParams
                        + ". Edita la fila en el catálogo y asigna un tipo a cada uno "
                        + "(en 'Tipos de parámetros', parte inferior del formulario).");
            }
        }

        // Format constraints (positive, no decimals, max length, ...)
        // run before the bind and accumulate every violation, unlike
        // ParamBinder's type check which rejects on the first one.
        if (def.paramConstraints() != null && !def.paramConstraints().isEmpty()) {
            Map<String, String> violations = ParamConstraintValidator
                    .validate(allParams, def.paramTypes(), def.paramConstraints());
            if (!violations.isEmpty()) {
                throw new ParamConstraintViolationException(violations);
            }
        }

        // The SQL is rewritten to `cast(:PH as TIPO)` per typed
        // placeholder and every value travels as text: PG applies the
        // cast in its own context (where search_path resolves the
        // academico_test DOMAIN types), so the JDBC type never matters.
        // ParamBinder.buildStrict rejects a Java value incompatible
        // with the declared type with a 400 naming the placeholder.
        log.debug("bind uuid={} paramTypes={} allParamsKeys={}",
                req.uuid(), def.paramTypes(), allParams.keySet());
        String rewrittenSql = SqlRewriter.rewrite(sql, def.paramTypes());
        MapSqlParameterSource params = ParamBinder.buildStrict(
                allParams, def.paramTypes(), Map.of());

        // The SQL runs as stored in the catalog. The only thing added
        // outside it is the audit-context CTE (see wrapWithAuditContext).
        String finalSql = isAuditWrappable(mode, def.httpMethod(), rewrittenSql)
                ? wrapWithAuditContext(rewrittenSql)
                : rewrittenSql;

        // Per-dialect bulkhead; fail fast (no wait) is the right call
        // for a sync MVC controller — execute() maps it to 503.
        var bulkhead = resilience.bulkheadFor(def.type() == null
                ? "default" : def.type());
        if (!bulkhead.tryAcquirePermission()) {
            throw BulkheadFullException.createBulkheadFullException(bulkhead);
        }
        try {
            boolean useCallable = "PROCEDURE".equals(mode)
                    && def.outParamNames() != null
                    && !def.outParamNames().isBlank();
            try {
                if (useCallable) {
                    log.debug("uuid={} using CallableStatement (outParams={})",
                            req.uuid(), def.outParamNames());
                    List<String> outNames = parseOutNames(def.outParamNames());
                    QueryResult result = executeCallable(jdbc, finalSql, params, outNames, def.paramTypes());
                    log.debug("uuid={} devolvió {} filas + {} OUT params (mode={})",
                            req.uuid(), result.rows().size(),
                            result.outParams() == null ? 0 : result.outParams().size(), mode);
                    return result;
                }

                // PROCEDURE (no OUT params) and DML: let JDBC say whether
                // there is a result set instead of assuming it.
                //   CALL sin retorno        -> envelope vacío
                //   CALL con INOUT          -> filas
                //   INSERT/UPDATE           -> rowsAffected
                //   INSERT ... RETURNING    -> filas
                if ("DML".equals(mode) || "PROCEDURE".equals(mode)) {
                    QueryResult result = jdbc.execute(finalSql, params,
                            (PreparedStatement ps) -> {
                                if (ps.execute()) {
                                    try (ResultSet rs = ps.getResultSet()) {
                                        List<Map<String, Object>> out = new ArrayList<>();
                                        int i = 0;
                                        while (rs.next()) {
                                            out.add(mapRow(rs, i++, objectMapper));
                                        }
                                        return QueryResult.rowsOnly(out);
                                    }
                                }
                                // A CALL reports no update count (-1);
                                // only emit rowsAffected when it exists.
                                int affected = ps.getUpdateCount();
                                return affected < 0
                                        ? QueryResult.rowsOnly(List.of())
                                        : QueryResult.rowsOnly(List.of(
                                                Map.of("rowsAffected", affected)));
                            });
                    log.debug("uuid={} ejecutado (mode={})", req.uuid(), mode);
                    return result;
                }

                List<Map<String, Object>> rows = jdbc.query(finalSql, params,
                        (rs, rn) -> mapRow(rs, rn, objectMapper));
                log.debug("uuid={} returned {} rows (mode={})", req.uuid(), rows.size(), mode);
                return QueryResult.rowsOnly(rows);
            } catch (DataAccessException dae) {
                throw PostgresErrorMapper.map(dae);
            }
        } finally {
            bulkhead.onComplete();
        }
    }

    /* ====================== parámetros del llamante ====================== */

    /** Upper-cased namespace prefix of {@code key}, or {@code null} without one. */
    private static String namespaceOf(String key) {
        int dot = key.indexOf('.');
        return dot <= 0 ? null : key.substring(0, dot).toUpperCase(Locale.ROOT);
    }

    private static boolean isCallerControlled(String key) {
        String ns = namespaceOf(key);
        return ParamNamespace.PARAM.equals(ns)
                || ParamNamespace.QUERY.equals(ns)
                || ParamNamespace.BODY.equals(ns)
                || ParamNamespace.BODY_RAW.equals(ns);
    }

    /** Case-insensitive, namespace-aware lookup — same rule ParamBinder applies. */
    private static boolean isDeclared(String key, Map<String, String> paramTypes) {
        if (paramTypes == null || paramTypes.isEmpty()) return false;
        if (paramTypes.containsKey(key)) return true;
        String canonical = ParamBinder.canonicalLookupKey(key);
        return canonical != null && paramTypes.containsKey(canonical);
    }

    /**
     * {@code :name} / {@code :NS.NAME.SUB} tokens; a {@code ::type} cast
     * is not a placeholder. Same name grammar Spring's
     * {@code NamedParameterUtils} applies (dots are part of the name).
     */
    private static final Pattern SQL_PLACEHOLDER =
            Pattern.compile("(?<![:\\w]):([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)");

    /** Placeholder names the SQL references, upper-cased. */
    static Set<String> referencedPlaceholders(String sql) {
        if (sql == null || sql.isEmpty()) return Set.of();
        Set<String> out = new HashSet<>();
        var m = SQL_PLACEHOLDER.matcher(sql);
        while (m.find()) {
            out.add(m.group(1).toUpperCase(Locale.ROOT));
        }
        return out;
    }

    /**
     * Removes from {@code params} every caller-controlled key
     * ({@code PARAM.*}, {@code QUERY.*}, {@code BODY.*},
     * {@code BODY_RAW.*}) that neither the SQL references nor the
     * catalog declares in {@code paramTypes}. Returns the removed keys.
     */
    static List<String> dropUnreferencedCallerParams(Map<String, Object> params,
                                                     Set<String> referenced,
                                                     Map<String, String> paramTypes) {
        List<String> ignored = new ArrayList<>();
        params.keySet().removeIf(k -> {
            if (!isCallerControlled(k) || isDeclared(k, paramTypes)) return false;
            String canonical = ParamBinder.canonicalLookupKey(k);
            if (referenced.contains(k.toUpperCase(Locale.ROOT))
                    || (canonical != null && referenced.contains(canonical))) {
                return false;
            }
            ignored.add(k);
            return true;
        });
        return ignored;
    }

    /* ====================== resultados ====================== */

    /**
     * LinkedHashMap preserves the column order from the
     * ResultSetMetaData — the UI depends on it for tabular rendering.
     */
    private static Map<String, Object> mapRow(ResultSet rs, int rn, ObjectMapper objectMapper)
            throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        int cols = md.getColumnCount();
        Map<String, Object> row = new LinkedHashMap<>(cols);
        for (int i = 1; i <= cols; i++) {
            row.put(md.getColumnLabel(i), normalizeColumnValue(rs.getObject(i), objectMapper));
        }
        return row;
    }

    /**
     * Converts a raw {@code ResultSet.getObject(i)} value into
     * something Jackson serializes as the JSON shape callers expect:
     *
     * <ul>
     *   <li>{@link java.sql.Array} (any native array column, e.g.
     *       {@code int8[]}) → a plain {@link List}. Jackson has no
     *       serializer for the driver's {@code PgArray} and would
     *       otherwise reflect over it, dumping the JDBC connection
     *       into the response.</li>
     *   <li>{@link PGobject} for {@code json}/{@code jsonb} → parsed
     *       into plain JDK types ({@link Map}, {@link List}, String,
     *       Number, Boolean) so the JSON nests instead of being
     *       double-encoded as a string. Plain JDK types on purpose:
     *       Spring Boot 4 ships Jackson 2 (what this code holds) next
     *       to Jackson 3 (what the HTTP converter writes with), and a
     *       Jackson-2 {@code JsonNode} is a foreign bean to the
     *       Jackson-3 writer. Any other PGobject type ({@code uuid},
     *       DOMAIN types) falls back to its text value.</li>
     * </ul>
     *
     * <p>Every other value already has a working serializer and passes
     * through unchanged.
     */
    static Object normalizeColumnValue(Object value, ObjectMapper objectMapper)
            throws SQLException {
        if (value instanceof java.sql.Array array) {
            try {
                Object javaArray = array.getArray();
                int len = java.lang.reflect.Array.getLength(javaArray);
                List<Object> out = new ArrayList<>(len);
                for (int i = 0; i < len; i++) {
                    out.add(java.lang.reflect.Array.get(javaArray, i));
                }
                return out;
            } finally {
                array.free();
            }
        }
        if (value instanceof PGobject pg) {
            String raw = pg.getValue();
            if (raw == null) return null;
            String type = pg.getType();
            if ("json".equals(type) || "jsonb".equals(type)) {
                try {
                    return objectMapper.readValue(raw, Object.class);
                } catch (JsonProcessingException e) {
                    // PG validated it on write, so this shouldn't happen;
                    // one malformed row isn't a reason to 500 the query.
                    log.warn("Column declared {} but its value didn't parse as JSON "
                            + "({}); returning it as plain text.", type, e.getMessage());
                    return raw;
                }
            }
            return raw;
        }
        return value;
    }

    /* ====================== PROCEDURE con OUT params ====================== */

    /**
     * Runs a PROCEDURE-mode row that declares OUT params via
     * {@link QueryDefinition#outParamNames()} through a
     * {@link CallableStatement}, once, and reads the OUT values back
     * keyed by the bare param name.
     *
     * <p>OUT params are registered as {@link Types#OTHER}: the PG
     * driver accepts it for any type and returns the value via
     * {@code getObject()}, which avoids guessing the SQL type. Works
     * for scalar types; composite/cursor OUT params are out of scope.
     */
    private QueryResult executeCallable(NamedParameterJdbcTemplate jdbc,
                                        String sql,
                                        MapSqlParameterSource params,
                                        List<String> outNames,
                                        Map<String, String> paramTypes) {
        Map<String, Integer> sqlTypes = resolveCallableTypes(params, paramTypes);

        return jdbc.getJdbcTemplate().execute(
                (Connection con) -> {
                    try (CallableStatement cs = con.prepareCall(sql)) {
                        for (Map.Entry<String, Object> e : params.getValues().entrySet()) {
                            Integer sqlType = sqlTypes.get(e.getKey());
                            if (sqlType != null && sqlType.intValue() != Types.ARRAY) {
                                cs.setObject(e.getKey(), e.getValue(), sqlType);
                            } else {
                                cs.setObject(e.getKey(), e.getValue());
                            }
                        }
                        for (String outName : outNames) {
                            cs.registerOutParameter(outName, Types.OTHER);
                        }
                        // Rows come from this same statement; the OUT
                        // values are only available once the result set
                        // is exhausted.
                        List<Map<String, Object>> rows = new ArrayList<>();
                        if (cs.execute()) {
                            try (ResultSet rs = cs.getResultSet()) {
                                int i = 0;
                                while (rs.next()) {
                                    rows.add(mapRow(rs, i++, objectMapper));
                                }
                            }
                        }
                        Map<String, Object> out = new LinkedHashMap<>();
                        for (String outName : outNames) {
                            out.put(outName, cs.getObject(outName));
                        }
                        return QueryResult.withOutParams(rows, out);
                    }
                });
    }

    /** {@code "out_a , out_b"} → {@code ["out_a", "out_b"]}. */
    private static List<String> parseOutNames(String csv) {
        return Arrays.stream(csv.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .collect(Collectors.toList());
    }

    /**
     * name → JDBC type for the IN/INOUT params of the CallableStatement.
     * Only entries with a declared type appear; arrays are excluded
     * because ParamBinder already wrapped them in a value that needs
     * the live Connection, so they bind untyped.
     */
    private static Map<String, Integer> resolveCallableTypes(
            MapSqlParameterSource params, Map<String, String> paramTypes) {
        Map<String, Integer> out = new HashMap<>();
        if (paramTypes == null || paramTypes.isEmpty()) return out;
        for (Map.Entry<String, Object> e : params.getValues().entrySet()) {
            String declared = paramTypes.get(e.getKey());
            if (declared == null) continue;
            Integer jdbcType = ParamTypes.JDBC_TYPES.get(declared);
            if (jdbcType == null) continue;
            if (ParamTypes.ARRAY_TYPES.contains(declared)) continue;
            out.put(e.getKey(), jdbcType);
        }
        return out;
    }

    /* ====================== ClickHouse LIMIT/OFFSET ====================== */

    private static final Pattern CH_PAGESIZE_PLACEHOLDER =
            Pattern.compile(":BODY\\.PAGESIZE\\b", Pattern.CASE_INSENSITIVE);
    private static final Pattern CH_PAGEOFFSET_PLACEHOLDER =
            Pattern.compile(":BODY\\.PAGEOFFSET\\b", Pattern.CASE_INSENSITIVE);
    private static final int CH_PAGE_SIZE_DEFAULT = 20;
    private static final int CH_PAGE_SIZE_MAX = 200;

    /**
     * Replaces {@code :BODY.PAGESIZE}/{@code :BODY.PAGEOFFSET} with
     * integer literals when {@code dialect} is {@code clickhouse}, and
     * removes the paging keys from {@code allParams} (mutated in place).
     *
     * <p>{@code BODY.PAGEOFFSET} is derived: the client sends
     * {@code pageIndex}/{@code pageSize}; the offset is
     * {@code pageIndex * pageSize}. No-op for any other dialect or
     * for SQL that references neither placeholder.
     *
     * @throws ResponseStatusException 400 if the SQL references the
     *         placeholders but pageSize/pageIndex aren't non-negative
     *         integers.
     */
    private static String substituteClickHouseLimitOffset(String sql, String dialect,
            Map<String, Object> allParams) {
        if (sql == null || sql.isEmpty()) return sql;
        if (!"clickhouse".equalsIgnoreCase(dialect)) return sql;

        boolean hasSize = CH_PAGESIZE_PLACEHOLDER.matcher(sql).find();
        boolean hasOffset = CH_PAGEOFFSET_PLACEHOLDER.matcher(sql).find();
        if (!hasSize && !hasOffset) return sql;

        int pageSize = parseNonNegativeIntOr400(
                allParams.remove(ParamNamespace.BODY + ".PAGESIZE"), "pageSize", CH_PAGE_SIZE_DEFAULT);
        int pageIndex = parseNonNegativeIntOr400(
                allParams.remove(ParamNamespace.BODY + ".PAGEINDEX"), "pageIndex", 0);
        allParams.remove(ParamNamespace.BODY + ".PAGEOFFSET");

        pageSize = Math.max(1, Math.min(pageSize, CH_PAGE_SIZE_MAX));
        long offset = (long) pageIndex * (long) pageSize;

        String result = CH_PAGESIZE_PLACEHOLDER.matcher(sql).replaceAll(String.valueOf(pageSize));
        result = CH_PAGEOFFSET_PLACEHOLDER.matcher(result).replaceAll(String.valueOf(offset));
        return result;
    }

    private static int parseNonNegativeIntOr400(Object value, String fieldName, int fallback) {
        if (value == null) return fallback;
        try {
            int parsed = Integer.parseInt(value.toString().trim());
            if (parsed < 0) {
                throw new NumberFormatException("negative");
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    fieldName + " debe ser un entero no negativo");
        }
    }

    /* ====================== CONTEXT.* ====================== */

    /**
     * Injects the {@code CONTEXT.*} values derived from the verified JWT.
     *
     * <p>They are NOT caller-controlled: the SecurityContextHolder is
     * filled from the parsed JWT, never from the request. The prefix
     * is what separates at a glance what the caller controls
     * ({@code PARAM.*}, {@code QUERY.*}, {@code BODY.*}) from what it
     * doesn't.
     *
     * <p>USER_ID/EMAIL/FAMILIA/SESION_ID are optional (older tokens,
     * anonymous public calls): when absent the placeholder is simply
     * not added and the procedure author decides what to do with the
     * absence. ROLES/ROLES_ARRAY/ESTABLISHMENT are always present
     * (empty when unknown) because queries reference them
     * unconditionally in their WHERE.
     */
    private static void injectContextParams(Map<String, Object> target,
                                            Authentication auth) {
        // Transport data (request id, path, ip...) goes in for every
        // call, authenticated or not.
        injectRequestParams(target);

        if (auth == null || !(auth.getPrincipal() instanceof AuthPrincipal p)) {
            return;
        }
        if (p.userId() != null) {
            target.put(ParamNamespace.CONTEXT + ".USER_ID", p.userId());
        }
        if (p.email() != null) {
            target.put(ParamNamespace.CONTEXT + ".EMAIL", p.email());
        }
        // family_id IS the session id in this system — one claim, two
        // placeholders so the audit columns can be named either way.
        if (p.familyId() != null) {
            target.put(ParamNamespace.CONTEXT + ".FAMILIA", p.familyId());
            target.put(ParamNamespace.CONTEXT + ".SESION_ID", p.familyId());
        }
        //   :CONTEXT.ROLES        → "ADMIN,EVALUADOR"  (LIKE en PL/pgSQL)
        //   :CONTEXT.ROLES_ARRAY  → "{ADMIN,EVALUADOR}" (text[] para ANY())
        String rolesCsv = p.roles() == null || p.roles().isEmpty()
                ? "" : String.join(",", p.roles());
        target.put(ParamNamespace.CONTEXT + ".ROLES", rolesCsv);
        target.put(ParamNamespace.CONTEXT + ".ROLES_ARRAY", "{" + rolesCsv + "}");
        target.put(ParamNamespace.CONTEXT + ".ESTABLISHMENT",
                p.establishment() == null ? "" : p.establishment());
    }

    /**
     * {@code :CONTEXT.REQUEST_ID}, {@code .PATH}, {@code .HTTP_METHOD},
     * {@code .CLIENT_IP}, {@code .USER_AGENT}, {@code .HEADERS} and
     * {@code .REQUEST_BODY} — what {@code fn_audit_ctx()} (V26) turns
     * into session GUCs through {@link #wrapWithAuditContext}.
     *
     * <ul>
     *   <li>REQUEST_ID: {@code X-Request-Id} if the gateway sent it,
     *       otherwise a UUID generated here, so the audit rows of this
     *       transaction can still be grouped.</li>
     *   <li>PATH is just the URI; the verb travels separately in
     *       HTTP_METHOD (its own ClickHouse column).</li>
     *   <li>CLIENT_IP: {@code X-Client-Ip} (set by api-gateway's
     *       {@code ClientIpGlobalFilter} from the real TCP connection;
     *       Spring Cloud Gateway drops {@code X-Forwarded-For}) →
     *       {@code X-Forwarded-For} (only relevant when not behind this
     *       gateway) → the direct connection address.</li>
     *   <li>HEADERS: JSON of {@link #HEADER_WHITELIST} only.
     *       {@code Authorization}/{@code Cookie} are session
     *       credentials, never audit context.</li>
     *   <li>REQUEST_BODY: JSON snapshot of the caller's params taken
     *       BEFORE this method adds its own CONTEXT.*, with sensitive
     *       keys ({@link #SENSITIVE_KEY_PATTERN}) redacted. Distinct
     *       from the row's fila_new/fila_old: this is what the client
     *       asked for, useful when it differs (defaults, triggers).</li>
     * </ul>
     *
     * <p>Reads the {@code HttpServletRequest} from
     * {@link RequestContextHolder} so no controller signature has to
     * carry it. Without a bound request (tests, internal calls)
     * nothing is added.
     */
    private static void injectRequestParams(Map<String, Object> target) {
        if (!(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes sra)) {
            return;
        }
        var req = sra.getRequest();

        Map<String, Object> redactedBody = redactSensitiveKeys(target);

        String requestId = req.getHeader("X-Request-Id");
        if (requestId == null || requestId.isBlank()) {
            requestId = UUID.randomUUID().toString();
        } else if (requestId.length() > 100) {
            // fn_audit_ctx / the ClickHouse LowCardinality column cap at 100.
            requestId = requestId.substring(0, 100);
        }
        target.put(ParamNamespace.CONTEXT + ".REQUEST_ID", requestId);
        target.put(ParamNamespace.CONTEXT + ".PATH", req.getRequestURI());
        target.put(ParamNamespace.CONTEXT + ".HTTP_METHOD", req.getMethod());

        String clientIp = req.getHeader("X-Client-Ip");
        if (clientIp == null || clientIp.isBlank()) {
            clientIp = req.getHeader("X-Forwarded-For");
            if (clientIp != null && !clientIp.isBlank()) {
                clientIp = clientIp.split(",")[0].trim();
            }
        }
        if (clientIp == null || clientIp.isBlank()) {
            clientIp = req.getRemoteAddr();
        }
        if (clientIp != null && !clientIp.isBlank()) {
            target.put(ParamNamespace.CONTEXT + ".CLIENT_IP", clientIp);
        }

        String userAgent = req.getHeader("User-Agent");
        if (userAgent != null && !userAgent.isBlank()) {
            target.put(ParamNamespace.CONTEXT + ".USER_AGENT", userAgent);
        }

        Map<String, String> headers = new LinkedHashMap<>();
        for (String name : HEADER_WHITELIST) {
            String value = req.getHeader(name);
            if (value != null && !value.isBlank()) {
                headers.put(name.toLowerCase(Locale.ROOT), value);
            }
        }
        if (!headers.isEmpty()) {
            target.put(ParamNamespace.CONTEXT + ".HEADERS", toJson(headers));
        }

        if (!redactedBody.isEmpty()) {
            target.put(ParamNamespace.CONTEXT + ".REQUEST_BODY", toJson(redactedBody));
        }
    }

    /* ====================== contexto de auditoría ====================== */

    /**
     * CTE prepended to write queries so {@code fn_audit_ctx()} sees the
     * request context. {@code MATERIALIZED} forces Postgres to run the
     * {@code set_config} calls BEFORE the subquery that calls the real
     * write function — query-service issues one top-level statement
     * per call, so a separate {@code set_config} statement would not
     * survive until the {@code fn_*}.
     *
     * <p>{@code :CONTEXT.USER_ID} is {@code public.users.id_user}, a
     * different id space from {@code TUSUARIO.PK_TUSUARIO}; the
     * {@code _actor} CTE resolves that bridge once. {@code app.user_id}
     * carries the readable name via {@code fn_resolver_actor} (raw PK
     * as last resort); {@code app.user_pk} always carries the raw PK.
     *
     * <p>{@code app.contexto} is MERGED ({@code ||}) with a pre-existing
     * value — {@code fn_audit_declarar} may already have set
     * sesion_id/familia — with {@code COALESCE} to {@code '{}'} for the
     * first write of the request.
     */
    private static final String AUDIT_CTX_CTE_HEADER =
            "WITH _actor AS MATERIALIZED (\n"
          + "  SELECT public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) AS pk_tusuario\n"
          + "),\n"
          + "_ctx AS MATERIALIZED (\n"
          + "  SELECT set_config('app.request_id', :CONTEXT.REQUEST_ID, true) AS _rid,\n"
          + "         set_config('app.http_method', :CONTEXT.HTTP_METHOD, true) AS _hm,\n"
          + "         set_config('app.client_ip', :CONTEXT.CLIENT_IP, true) AS _ip,\n"
          + "         set_config('app.user_agent', :CONTEXT.USER_AGENT, true) AS _ua,\n"
          + "         set_config('app.headers', :CONTEXT.HEADERS, true) AS _hdrs,\n"
          + "         set_config('app.request_body', :CONTEXT.REQUEST_BODY, true) AS _body,\n"
          + "         set_config('app.user_id', COALESCE(academico_test.fn_resolver_actor((SELECT pk_tusuario FROM _actor)), (SELECT pk_tusuario FROM _actor)::text), true) AS _uid,\n"
          + "         set_config('app.user_pk', (SELECT pk_tusuario FROM _actor)::text, true) AS _upk,\n"
          + "         set_config('app.contexto', (COALESCE(NULLIF(current_setting('app.contexto', true), '')::jsonb, '{}'::jsonb) || jsonb_build_object('path', :CONTEXT.PATH, 'sesion_id', :CONTEXT.SESION_ID, 'familia', :CONTEXT.FAMILIA))::text, true) AS _c\n"
          + ")\n"
          + "SELECT _orig.* FROM _ctx, (";

    private static final String AUDIT_CTX_CTE_FOOTER = ") AS _orig";

    /**
     * Every audited write function in the schema is an
     * {@code academico_test.fn_*}; textual and case-insensitive, so a
     * new module needs no maintenance here.
     */
    private static final Pattern ACADEMICO_TEST_FN_CALL =
            Pattern.compile("academico_test\\.fn_", Pattern.CASE_INSENSITIVE);

    /**
     * Gate for the automatic audit-context wrap:
     * <ul>
     *   <li>Only SELECT/FUNCTION: the wrap puts the original SQL as a
     *       subquery in a FROM, which a direct INSERT/UPDATE (DML) or a
     *       CALL (PROCEDURE) can't be.</li>
     *   <li>The SQL must call {@code academico_test.fn_*}; otherwise a
     *       plain read-only SELECT whose legacy row never declared a
     *       verb (defaulting to POST) would get wrapped for nothing,
     *       and break on non-Postgres datasources.</li>
     *   <li>A null httpMethod counts as a write (POST is the historic
     *       default): wrapping too much is harmless, missing a real
     *       write is not.</li>
     * </ul>
     */
    static boolean isAuditWrappable(String mode, String httpMethod, String sql) {
        boolean wrappableMode = "SELECT".equals(mode) || "FUNCTION".equals(mode);
        boolean isWrite = !"GET".equalsIgnoreCase(httpMethod == null ? "POST" : httpMethod);
        return wrappableMode && isWrite && ACADEMICO_TEST_FN_CALL.matcher(sql).find();
    }

    static String wrapWithAuditContext(String sql) {
        String trimmed = sql.strip();
        if (trimmed.endsWith(";")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        return AUDIT_CTX_CTE_HEADER + trimmed + AUDIT_CTX_CTE_FOOTER + ";";
    }

    /**
     * Headers allowed into {@code :CONTEXT.HEADERS}. Deliberately no
     * {@code Authorization}/{@code Cookie}; {@code X-Forwarded-For} is
     * captured separately as {@code :CONTEXT.CLIENT_IP}.
     */
    private static final List<String> HEADER_WHITELIST =
            List.of("User-Agent", "Accept-Language", "Referer");

    /**
     * Placeholder names that must never reach ClickHouse in plain text
     * inside {@code :CONTEXT.REQUEST_BODY}. Matched against the local
     * name (after the namespace), case-insensitive.
     */
    private static final Pattern SENSITIVE_KEY_PATTERN =
            Pattern.compile("(?i).*(TOKEN|SECRET|PASSWORD|CONTRASENA|CONTRASEÑA).*");

    private static final ObjectMapper CONTEXT_MAPPER = new ObjectMapper();

    private static Map<String, Object> redactSensitiveKeys(Map<String, Object> source) {
        Map<String, Object> copy = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : source.entrySet()) {
            String key = e.getKey();
            int dot = key.indexOf('.');
            String localName = dot >= 0 ? key.substring(dot + 1) : key;
            copy.put(key, SENSITIVE_KEY_PATTERN.matcher(localName).matches()
                    ? "[REDACTED]" : e.getValue());
        }
        return copy;
    }

    private static String toJson(Object value) {
        try {
            return CONTEXT_MAPPER.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            log.warn("No se pudo serializar un valor de CONTEXT.* a JSON: {}", e.getMessage());
            return null;
        }
    }

    /* ====================== guardas ====================== */

    /**
     * Lightweight SQL guard. Accepts statements whose first
     * keyword (case-insensitive, after stripping leading
     * whitespace and {@code --} comments) is {@code SELECT}
     * or {@code WITH}. Everything else — INSERT, UPDATE,
     * DELETE, MERGE, CREATE, DROP, ALTER, GRANT, REVOKE,
     * TRUNCATE, CALL — is rejected.
     *
     * <p>We deliberately do NOT try to parse SQL — that's a
     * losing game for general text. The catalog authorization
     * check plus the admin-only CRUD endpoint are the actual
     * defenses; this is just the last-mile guard.
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
        while (s.startsWith("--")) {
            int nl = s.indexOf('\n');
            if (nl < 0) return "";
            s = s.substring(nl + 1).stripLeading();
        }
        return s;
    }

    /**
     * The authenticated principal, or {@code null} for anonymous
     * callers (only the public path lets them through; elsewhere
     * Spring Security already answered 403).
     */
    private static Authentication currentAuthentication() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal) {
            return auth;
        }
        return null;
    }

    /**
     * The raw bearer token that
     * {@link com.co.eurekatic.query.security.JwtAuthenticationFilter}
     * stored as {@link Authentication#getCredentials()}; the catalog
     * re-validates it.
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
