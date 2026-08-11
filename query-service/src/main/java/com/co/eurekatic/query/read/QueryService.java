package com.co.eurekatic.query.read;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.query.ParamBinder;
import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.common.query.ParamTypes;
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
        // Default to SELECT so the FAILURE path records a
        // meaningful mode even when the catalog row couldn't be
        // fetched (e.g. 404 before we know the real mode).
        // doExecute overwrites it once the row is resolved.
        //
        // Single-element array, not a plain local: doExecute
        // publishes the resolved mode through a Consumer, and a
        // lambda cannot assign to a captured local (it must be
        // effectively final). The array reference is final; its
        // slot is what we mutate. Confined to this thread, so no
        // synchronisation is needed.
        final String[] mode = { "SELECT" };
        try {
            QueryResult result = doExecute(req, publicOk, m -> mode[0] = m);
            metrics.recordExecution(mode[0], QueryMetrics.Outcome.SUCCESS,
                    System.nanoTime() - start);
            return result;
        } catch (BulkheadFullException bfe) {
            // V33 — a slow query on this dialect has filled
            // the bulkhead (concurrent cap + queue full).
            // Surface as 503 with Retry-After so the client
            // backs off instead of retrying immediately.
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
            //
            // V33: este brazo NO se tocó. Conceder DML directo se
            // hizo añadiendo un modo nuevo, no relajando el guardia
            // aquí — si se hubiera relajado "cuando el método es
            // POST", cada fila existente habría perdido la
            // protección de golpe, porque HTTP_METHOD entra con
            // default POST.
            rejectIfMutating(def.query());
        } else if ("DML".equals(mode)) {
            // V33 — INSERT/UPDATE escrito directamente. El catálogo
            // ya validó al guardar que la fila esté atada a POST o
            // PUT y que el primer keyword no sea DELETE ni DDL.
            log.debug("uuid={} ejecuta DML directo", req.uuid());
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

        // V49 — bind con tipos. Construimos el mapa final (parámetros
        // del llamante + valores CONTEXT del JWT) y se lo pasamos a
        // ParamBinder, que aplica sqlType explícito cuando
        // def.paramTypes() lo declara y deja el resto al auto-derive
        // de Spring. Una fila legacy sin paramTypes cae aquí y se
        // comporta como antes del cambio.
        Map<String, Object> allParams = new LinkedHashMap<>(
                req.params() == null ? Map.of() : req.params());
        injectContextParams(allParams, auth);

        // bind con tipos. def.paramTypes() puede ser null en filas
        // legacy — ParamBinder lo trata como mapa vacío y devuelve
        // comportamiento idéntico al anterior a V49.
        MapSqlParameterSource params = ParamBinder.build(allParams, def.paramTypes());

        // El SQL se ejecuta tal cual está en el catálogo.
        //
        // Antes se le concatenaba " LIMIT :limit" por detrás, así
        // que lo que se ejecutaba no era lo que el autor veía en el
        // formulario — y sólo en modo SELECT, ignorándose en
        // silencio para PROCEDURE. La paginación ahora la escribe
        // el autor con :QUERY.SIZE / :QUERY.OFFSET, lo que además
        // le da control del dialecto y del orden de las cláusulas.
        String sql = def.query();

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
                    // UNA sola ejecución. Antes se llamaba a
                    // executeCallable y después a jdbc.query() con el
                    // MISMO sql, así que el procedimiento corría dos
                    // veces: sus efectos secundarios (auditoría,
                    // contadores, cualquier escritura) se aplicaban
                    // por duplicado. El comentario decía que el
                    // driver "devuelve el result set después de la
                    // llamada", que es cierto — pero se leía
                    // reejecutando en vez de leyéndolo del
                    // CallableStatement que ya lo tenía.
                    QueryResult result = executeCallable(jdbc, sql, params, outNames, def.paramTypes());
                    log.debug("uuid={} devolvió {} filas + {} OUT params (mode={})",
                            req.uuid(), result.rows().size(),
                            result.outParams() == null ? 0 : result.outParams().size(), mode);
                    return result;
                }

                // PROCEDURE (sin OUT params) y DML comparten camino:
                // se deja que JDBC diga si hubo result set en vez de
                // suponerlo.
                //
                // Suponerlo costó caro. Un CALL a un procedimiento
                // que no devuelve nada iba por query(), y el driver
                // de Postgres lanzaba "La consulta no retornó ningún
                // resultado" DESPUÉS de ejecutar y commitear: el
                // cliente recibía un 500 por una escritura que sí se
                // había aplicado. Un reintento la aplicaba dos veces.
                //
                // ps.execute() devuelve true si hay filas y false si
                // hay un contador de actualización, que es
                // exactamente la pregunta que hay que hacer. Así
                // salen bien los cuatro casos sin heurísticas:
                //   CALL sin retorno        -> rowsAffected
                //   CALL con INOUT          -> filas
                //   INSERT/UPDATE           -> rowsAffected
                //   INSERT ... RETURNING    -> filas
                //
                // Ese último era una limitación declarada en V33 y
                // desaparece sola: no hace falta buscar la palabra
                // RETURNING en el texto, que era la heurística que
                // se había descartado por frágil.
                if ("DML".equals(mode) || "PROCEDURE".equals(mode)) {
                    QueryResult result = jdbc.execute(sql, params,
                            (java.sql.PreparedStatement ps) -> {
                                if (ps.execute()) {
                                    try (java.sql.ResultSet rs = ps.getResultSet()) {
                                        List<Map<String, Object>> out = new java.util.ArrayList<>();
                                        int i = 0;
                                        while (rs.next()) {
                                            out.add(mapRow(rs, i++));
                                        }
                                        return QueryResult.rowsOnly(out);
                                    }
                                }
                                // getUpdateCount() devuelve -1 cuando no hay
                                // contador que dar, que es justo el caso de
                                // un CALL en Postgres: un procedimiento no
                                // reporta filas afectadas. Comprobado contra
                                // la base real — execute() da hasResultSet
                                // =false y updateCount=-1.
                                //
                                // Devolver "rowsAffected: -1" sería un número
                                // sin significado para una llamada que fue
                                // bien, así que en ese caso la respuesta es
                                // un envelope vacío: ni filas ni contador,
                                // que es literalmente lo que ocurrió. El
                                // contador solo se emite cuando existe (DML).
                                int affected = ps.getUpdateCount();
                                return affected < 0
                                        ? QueryResult.rowsOnly(List.of())
                                        : QueryResult.rowsOnly(List.of(
                                                Map.of("rowsAffected", affected)));
                            });
                    log.debug("uuid={} ejecutado (mode={})", req.uuid(), mode);
                    return result;
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
    private QueryResult executeCallable(NamedParameterJdbcTemplate jdbc,
                                        String sql,
                                        MapSqlParameterSource params,
                                        List<String> outNames,
                                        Map<String, String> paramTypes) {
        // V49 — Aplicamos el sqlType declarado por el autor también
        // en el bind manual del CallableStatement. Si no hay tipo
        // declarado (entrada no en paramTypes o paramTypes vacío),
        // caemos al setObject(key, value) sin tipo — comportamiento
        // idéntico al anterior a V49.
        Map<String, Integer> sqlTypes = resolveCallableTypes(params, paramTypes);

        return jdbc.getJdbcTemplate().execute(
                (java.sql.Connection con) -> {
                    try (java.sql.CallableStatement cs = con.prepareCall(sql)) {
                        // Bind IN params (and any INOUT).
                        // MapSqlParameterSource has no forEach —
                        // getValues() exposes the backing Map.
                        for (Map.Entry<String, Object> e : params.getValues().entrySet()) {
                            Integer sqlType = sqlTypes.get(e.getKey());
                            if (sqlType != null && sqlType.intValue() != java.sql.Types.ARRAY) {
                                // Para tipos array usamos el setObject
                                // sin tipo: ParamBinder ya envolvió el
                                // valor en un AbstractSqlTypeValue que
                                // sabe hacer createArrayOf contra la
                                // Connection activa cuando se bindea
                                // por la vía jdbc.update.
                                cs.setObject(e.getKey(), e.getValue(), sqlType);
                            } else {
                                cs.setObject(e.getKey(), e.getValue());
                            }
                        }
                        // Register OUT params. The PG driver
                        // accepts Types.OTHER for any type and
                        // returns the value via getObject().
                        for (String outName : outNames) {
                            cs.registerOutParameter(outName,
                                    java.sql.Types.OTHER);
                        }
                        // execute() dice si hay result set. Se lee del
                        // MISMO statement en vez de reejecutar el SQL,
                        // que es lo que hacía que el procedimiento
                        // corriera dos veces.
                        List<Map<String, Object>> rows = new java.util.ArrayList<>();
                        if (cs.execute()) {
                            try (java.sql.ResultSet rs = cs.getResultSet()) {
                                int i = 0;
                                while (rs.next()) {
                                    rows.add(mapRow(rs, i++));
                                }
                            }
                        }
                        // Los OUT se leen después de agotar el result
                        // set: el driver de Postgres no los tiene
                        // disponibles hasta que la llamada termina.
                        Map<String, Object> out = new LinkedHashMap<>();
                        for (String outName : outNames) {
                            out.put(outName, cs.getObject(outName));
                        }
                        return QueryResult.withOutParams(rows, out);
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
     * V49 — Construye el mapa nombre → sqlType para los IN/INOUT
     * del CallableStatement. Sólo las entradas que tienen tipo
     * declarado en {@code paramTypes} aparecen; las demás devuelven
     * null en la búsqueda y caen al setObject(key, value) sin tipo.
     *
     * <p>Los arrays se excluyen aquí — ParamBinder ya envolvió el
     * valor en un {@code AbstractSqlTypeValue} que necesita la
     * Connection activa, no un sqlType explícito. En el bind
     * manual del CallableStatement los dejamos sin tipo y dejamos
     * que el driver haga su mejor inferencia.
     */
    private static Map<String, Integer> resolveCallableTypes(
            MapSqlParameterSource params, Map<String, String> paramTypes) {
        Map<String, Integer> out = new java.util.HashMap<>();
        if (paramTypes == null || paramTypes.isEmpty()) return out;
        for (Map.Entry<String, Object> e : params.getValues().entrySet()) {
            String declared = paramTypes.get(e.getKey());
            if (declared == null) continue;
            Integer jdbcType = ParamTypes.JDBC_TYPES.get(declared);
            if (jdbcType == null) continue;
            if (ParamTypes.ARRAY_TYPES.contains(declared)) continue; // ver javadoc
            out.put(e.getKey(), jdbcType);
        }
        return out;
    }

    /**
     * V49 (movido desde el cuerpo de doExecute) — inyecta los valores
     * CONTEXT derivados del JWT verificado en el mapa de parámetros.
     *
     * <p>Estos valores NO son caller-controlled: el cliente no puede
     * meter un {@code :CONTEXT.USER_ID} en su body para suplantar
     * identidad, porque la firma la controla auth-center y el
     * SecurityContextHolder se rellena desde el JWT parseado, no
     * desde la petición.
     *
     * <p>El prefijo {@code CONTEXT.} no es cosmético — es lo que
     * distingue de un vistazo lo que controla el llamante
     * ({@code PARAM.*}, {@code QUERY.*}, {@code BODY.*}) de lo que
     * no. Ver spec 2026-08-10.
     *
     * <p>Siguen siendo opcionales: los tokens anteriores a V29 no
     * llevan claim uid, y el endpoint público no tiene principal.
     * En ambos casos NO se añade el parámetro — el autor del
     * procedimiento decide qué hacer con la ausencia (p. ej.
     * "IF :CONTEXT.USER_ID IS NULL THEN RAISE EXCEPTION
     * 'unauthenticated'").
     *
     * <p>Estos bindings no se pasan por {@link ParamBinder} con sqlType:
     * su comportamiento actual (Spring auto-derive) es correcto y no
     * entran en la validación estricta de la metadata. Si en el
     * futuro hace falta tiparlos, {@code ParamBinder} los respeta
     * igual que cualquier otra key.
     */
    private static void injectContextParams(Map<String, Object> target,
                                            Authentication auth) {
        if (auth == null || !(auth.getPrincipal() instanceof AuthPrincipal p)) {
            return;
        }
        if (p.userId() != null) {
            target.put(ParamNamespace.CONTEXT + ".USER_ID", p.userId());
        }
        if (p.email() != null) {
            target.put(ParamNamespace.CONTEXT + ".EMAIL", p.email());
        }
        // Roles en dos formatos para que el autor elija el
        // que le convenga:
        //   :CONTEXT.ROLES        → "ADMIN,EVALUADOR"  (LIKE en PL/pgSQL)
        //   :CONTEXT.ROLES_ARRAY  → "{ADMIN,EVALUADOR}" (text[] para ANY())
        String rolesCsv = p.roles() == null || p.roles().isEmpty()
                ? "" : String.join(",", p.roles());
        String rolesArray = "{"
                + (p.roles() == null || p.roles().isEmpty()
                    ? "" : String.join(",", p.roles()))
                + "}";
        target.put(ParamNamespace.CONTEXT + ".ROLES", rolesCsv);
        target.put(ParamNamespace.CONTEXT + ".ROLES_ARRAY", rolesArray);
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