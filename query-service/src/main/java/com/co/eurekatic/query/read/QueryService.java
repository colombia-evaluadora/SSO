package com.co.eurekatic.query.read;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.query.ParamBinder;
import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.common.query.ParamTypes;
import com.co.eurekatic.common.query.SqlRewriter;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.exception.PostgresErrorMapper;
import com.co.eurekatic.query.observability.QueryMetrics;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.web.QueryRequest;
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

import java.sql.SQLException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

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
    private final com.fasterxml.jackson.databind.ObjectMapper objectMapper;

    public QueryService(CatalogClient catalog, JdbcTemplateRegistry registry,
                         QueryMetrics metrics, QueryResilience resilience,
                         com.fasterxml.jackson.databind.ObjectMapper objectMapper) {
        this.catalog = catalog;
        this.registry = registry;
        this.metrics = metrics;
        this.resilience = resilience;
        this.objectMapper = objectMapper;
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
        //
        // V60-bis — case-insensitive lookups: el cliente puede
        // mandar las keys del body en cualquier caja. NO las
        // mutamos aquí — Spring JDBC bindea
        // case-sensitively contra los placeholders del SQL,
        // así que cambiar la key rompería SQL legacy escrito
        // con placeholders lowercase. En su lugar,
        // {@code ParamBinder.buildStrict} hace lookup
        // case-insensitive y namespace-aware contra
        // paramTypes para encontrar el tipo declarado.
        Map<String, Object> allParams = new LinkedHashMap<>(
                req.params() == null ? Map.of() : req.params());
        injectContextParams(allParams, auth);

        // V49 (defence in depth) — si un placeholder caller-controlled
        // (':PARAM.*' / ':BODY.*') llega al bind sin tipo declarado,
        // ParamBinder cae al auto-derive de Spring, que bindea un String
        // como VARCHAR. Eso rompe cualquier firma de función/SELECT que
        // espere otro tipo — el síntoma exacto es
        // "function xxx(character varying, bigint) does not exist",
        // que es lo que el operador veía en producción porque las
        // filas heredadas pre-V49 quedaron con paramTypes='{}' y la
        // validación strict de sso-admin sólo dispara al guardar.
        //
        // En lugar de ejecutar y devolver un 500 con PG críptico,
        // rechazamos en runtime con un 400 que nombra los placeholders
        // sin tipo y le dice al autor qué hacer. Mismo set curado que
        // la validación al guardar; si la fila ya está bien guardada,
        // esta lista viene vacía y el bind sigue como siempre.
        if (def.paramTypes() != null) {
            List<String> untypedCallerParams = allParams.keySet().stream()
                    .filter(k -> {
                        int dot = k.indexOf('.');
                        if (dot <= 0) return false;
                        String ns = k.substring(0, dot);
                        return ParamNamespace.PARAM.equals(ns.toUpperCase(java.util.Locale.ROOT))
                                || ParamNamespace.BODY.equals(ns.toUpperCase(java.util.Locale.ROOT));
                    })
                    // V60-bis — case-insensitive: el cliente
                    // puede mandar la key en cualquier caja.
                    // Buscamos primero literal y luego
                    // canonical (MAYÚSCULAS + namespace
                    // prefix).
                    .filter(k -> !def.paramTypes().containsKey(k)
                            && !def.paramTypes().containsKey(
                                    com.co.eurekatic.common.query.ParamBinder.canonicalLookupKey(k)))
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

        // bind con tipos. def.paramTypes() puede ser null en filas
        // legacy — ParamBinder lo trata como mapa vacío y devuelve
        // comportamiento idéntico al anterior a V49.
        //
        // V49-bis: el SQL se reescribe ANTES del bind para insertar
        // `cast(:PH as TIPO)` por cada placeholder tipado. Eso elimina
        // la dependencia del tipo JDBC — ParamBinder pasa texto puro
        // y PG aplica el cast en su contexto (donde search_path sí
        // resuelve academico_test.* para los DOMAIN types).
        //
        // V49 diagnostics — imprimo lo que ParamBinder va a ver.
        // Si el bug del bind sigue siendo "todo se pasa como
        // string" en runtime, este log muestra exactamente qué
        // mapa llegó desde el catálogo. La pista es si
        // def.paramTypes() viene vacío cuando la fila sí lo
        // tiene persistido — eso aísla si el bug está aguas
        // arriba (Jackson, JSONB) o aguas abajo (binder).
        log.info("V49-bind uuid={} paramTypes={} allParamsKeys={}",
                req.uuid(), def.paramTypes(), allParams.keySet());
        String originalSql = def.query();
        String rewrittenSql = SqlRewriter.rewrite(originalSql, def.paramTypes());
        if (!originalSql.equals(rewrittenSql)) {
            log.debug("V49-rewrite uuid={} rewrittenSql={}",
                    req.uuid(), rewrittenSql);
        }
        // V60 — bind con validación de tipos. Atrapa los casos
        // donde el cliente envía un String/Boolean donde el
        // catálogo declara BIGINT, o un array mixto en un
        // BIGINT[] — antes caían al cast PG con SQLSTATE 22P02
        // y un mensaje críptico. Ahora el binder rechaza con
        // 400 nombrando el placeholder y el tipo esperado.
        // El Illega aquí como respuesta llamada cuando el
        // bind actual se GeneralExceptionHandler lo mapea a 400
        // con el envelope estándar.
        MapSqlParameterSource params = ParamBinder.buildStrict(
                allParams, def.paramTypes(), java.util.Map.of());

        // El SQL se ejecuta tal cual está en el catálogo.
        //
        // Antes se le concatenaba " LIMIT :limit" por detrás, así
        // que lo que se ejecutaba no era lo que el autor veía en el
        // formulario — y sólo en modo SELECT, ignorándose en
        // silencio para PROCEDURE. La paginación ahora la escribe
        // el autor con :QUERY.SIZE / :QUERY.OFFSET, lo que además
        // le da control del dialecto y del orden de las cláusulas.
        //
        // V-audit-ctx-2 — la ÚNICA excepción: el wrap de contexto de
        // auditoría (ver wrapWithAuditContext) SÍ se le añade por
        // fuera del catálogo, nunca a través de él. Antes (V80) el
        // wrap vivía como texto literal dentro de la fila
        // `public.query.query` — el autor lo veía (y podía romperlo)
        // en el editor SQL del catálogo, y una lista de id_query
        // hardcodeada decidía a qué filas aplicaba, lista que había
        // que regenerar a mano por ambiente. Ahora es automático:
        // CUALQUIER query en modo SELECT/FUNCTION que invoque una
        // función academico_test.fn_* (la convención de nombres que
        // TODAS las funciones de escritura auditadas siguen) y cuyo
        // verbo no sea GET lo recibe, sin que el catálogo sepa que
        // existe — no hace falta curar una lista ni tocar SQL
        // guardado cuando se agrega una función nueva.
        String sql = isAuditWrappable(mode, def.httpMethod(), rewrittenSql)
                ? wrapWithAuditContext(rewrittenSql)
                : rewrittenSql;

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
                                            out.add(mapRow(rs, i++, objectMapper));
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
                        (rs, rn) -> mapRow(rs, rn, objectMapper));

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
    private static Map<String, Object> mapRow(java.sql.ResultSet rs, int rn,
                                              com.fasterxml.jackson.databind.ObjectMapper objectMapper)
            throws java.sql.SQLException {
        java.sql.ResultSetMetaData md = rs.getMetaData();
        int cols = md.getColumnCount();
        Map<String, Object> row = new LinkedHashMap<>(cols);
        for (int i = 1; i <= cols; i++) {
            row.put(md.getColumnLabel(i), normalizeColumnValue(rs.getObject(i), objectMapper));
        }
        return row;
    }

    /**
     * Converts a raw {@code ResultSet.getObject(i)} value into
     * something Jackson can serialize as the JSON shape callers
     * actually expect. Without this, two PostgreSQL JDBC types
     * leak the driver's internals into the response:
     *
     * <ul>
     *   <li>{@link java.sql.Array} (any native array column, e.g.
     *       {@code int8[]}) — Jackson has no built-in serializer
     *       for it, so it fell back to reflecting over the
     *       driver's {@code PgArray} bean properties, dumping the
     *       whole JDBC {@code Connection} (URL, backend PID, the
     *       full keyword list, …) into the response body. We
     *       extract the actual element array via
     *       {@link java.sql.Array#getArray()} and return it as a
     *       {@link List} — a plain JSON array, exactly what a
     *       column typed {@code int8[]} should produce.</li>
     *   <li>{@link PGobject} ({@code json}/{@code jsonb} columns,
     *       and any other PG type the driver doesn't map to a
     *       plain Java type, e.g. {@code uuid} or a DOMAIN type)
     *       — Jackson serialized the wrapper itself
     *       ({@code {"type":"jsonb","value":"<the json as a
     *       string>"}}), double-encoding the JSON instead of
     *       nesting it. For {@code json}/{@code jsonb} we parse
     *       the raw text into plain JDK types ({@link Map},
     *       {@link List}, {@code String}, {@code Number},
     *       {@code Boolean}) so it serializes as nested JSON.
     *
     *       <p>We deliberately deserialize to plain JDK
     *       collections instead of a Jackson-specific tree type
     *       ({@code JsonNode}) or a "write this verbatim" wrapper
     *       ({@code RawValue}): Spring Boot 4 ships {@code
     *       com.fasterxml.jackson.databind} (Jackson 2, what this
     *       service's own code and the {@code ObjectMapper} bean
     *       we're holding here are built against) ALONGSIDE
     *       Jackson 3's {@code tools.jackson.databind} — which is
     *       what the HTTP response converter that actually writes
     *       the wire bytes uses by default. A Jackson-2
     *       {@code JsonNode}/{@code RawValue} instance is a
     *       foreign type to that Jackson-3 writer, which doesn't
     *       recognize it and falls back to reflecting over its
     *       bean-style getters ({@code isObject()}, {@code
     *       getNodeType()}, …) instead of its content — same
     *       failure mode as the original bug, just one level
     *       removed. {@code Map}/{@code List}/{@code String}/
     *       {@code Number}/{@code Boolean} are core JDK types
     *       every JSON library — either Jackson generation, or
     *       whatever replaces them — serializes correctly without
     *       needing to recognize anything Jackson-specific. Any
     *       other PGobject-backed type falls back to its plain
     *       text value.</li>
     * </ul>
     *
     * <p>Every other value (String, Long, Boolean, java.sql.Date,
     * …) already has a working Jackson serializer and passes
     * through unchanged.
     */
    static Object normalizeColumnValue(Object value,
                                       com.fasterxml.jackson.databind.ObjectMapper objectMapper)
            throws java.sql.SQLException {
        if (value instanceof java.sql.Array array) {
            try {
                Object javaArray = array.getArray();
                int len = java.lang.reflect.Array.getLength(javaArray);
                List<Object> out = new java.util.ArrayList<>(len);
                for (int i = 0; i < len; i++) {
                    out.add(java.lang.reflect.Array.get(javaArray, i));
                }
                return out;
            } finally {
                // Releases the driver-side resources backing the
                // array now that we've copied its elements out —
                // JDBC best practice, not required for correctness
                // here since the ResultSet itself is closed right
                // after, but cheap and avoids relying on that.
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
                } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
                    // Postgres already validated this as JSON when
                    // it went into the column, so this shouldn't
                    // happen — but a single malformed row isn't a
                    // reason to 500 the whole query. Fall back to
                    // the plain text; the client still gets the
                    // data, just not parsed.
                    log.warn("Column declared {} but its value didn't parse as JSON "
                            + "({}); returning it as plain text.", type, e.getMessage());
                    return raw;
                }
            }
            return raw;
        }
        return value;
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
                                    rows.add(mapRow(rs, i++, objectMapper));
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
        // V-audit-ctx — REQUEST_ID/PATH van SIEMPRE, autenticado o no: son
        // datos del transporte HTTP (de dónde vino el request), no de la
        // identidad. Colocados antes del `return` temprano de abajo para
        // que un query público también los tenga disponibles.
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
     * V-audit-ctx — :CONTEXT.REQUEST_ID, :CONTEXT.PATH y :CONTEXT.HTTP_METHOD,
     * para que el catálogo pueda hacer {@code set_config('app.request_id', ...)}
     * / {@code set_config('app.http_method', ...)} y fundir {@code path} en
     * {@code app.contexto} en la misma sentencia que la escritura real (ver
     * {@code fn_audit_ctx()}, {@code postgres/migrations/V26__context-emitter.sql}).
     * {@code HTTP_METHOD} tiene su propia columna en ClickHouse (para
     * filtrar/agrupar por verbo sin parsear un string) — por eso {@code PATH}
     * es solo la URI, **sin** el método como prefijo; repetirlo en las dos
     * partes sería redundante.
     *
     * <p>Mismo patrón que {@code AuditContextAspect} de la app de
     * referencia (db-migrations/api): {@code X-Request-Id} si el
     * cliente/gateway ya lo mandó, si no un UUID generado aquí — un
     * request sin id de correlación es peor que uno con un id que
     * nadie más va a reusar, porque igual permite agrupar las filas
     * de auditoría de ESTA transacción.
     *
     * <p>No dependemos de que el llamado venga por un {@code
     * @Controller} concreto — {@link RequestContextHolder} expone el
     * {@code HttpServletRequest} del hilo actual sin necesidad de
     * inyectarlo en cada firma de método intermedio. Si no hay
     * request ligado al hilo (tests, llamadas internas), no se agrega
     * nada — igual que el resto de los CONTEXT.* opcionales.
     *
     * <p>V-audit-ctx-2 agrega cuatro placeholders más, todos para
     * auditoría de seguridad ("¿desde dónde y con qué se hizo este
     * cambio?"), no de negocio:
     * <ul>
     *   <li>{@code :CONTEXT.CLIENT_IP} — {@code X-Client-Ip} (header
     *       propio, seteado por {@code ClientIpGlobalFilter} en
     *       api-gateway a partir de la conexión TCP real; DELIBERADAMENTE
     *       no {@code X-Forwarded-For} — Spring Cloud Gateway 5 lo
     *       descarta antes de reenviar la petición, confirmado
     *       empíricamente). Fallback a {@code X-Forwarded-For} (por si
     *       algo llama a query-service sin pasar por este gateway) y
     *       finalmente a la IP de la conexión TCP directa.</li>
     *   <li>{@code :CONTEXT.USER_AGENT} — el header tal cual.</li>
     *   <li>{@code :CONTEXT.HEADERS} — JSON de una whitelist explícita
     *       ({@link #HEADER_WHITELIST}). {@code Authorization}/{@code
     *       Cookie} NUNCA se incluyen, ni siquiera redactados — son
     *       credenciales de sesión, no contexto de auditoría, y no
     *       tienen nada que hacer en ClickHouse en texto plano.</li>
     *   <li>{@code :CONTEXT.REQUEST_BODY} — JSON de lo que el cliente
     *       pidió escribir (snapshot de {@code target} ANTES de que
     *       este método agregue sus propios {@code CONTEXT.*}), con
     *       claves sensibles ({@link #SENSITIVE_KEY_PATTERN} — token,
     *       secret, password) redactadas. Distinto de
     *       {@code fila_new}/{@code fila_old} en ClickHouse, que son
     *       el estado de la fila DESPUÉS de escribir — esto es lo que
     *       el cliente pidió, útil cuando difiere (defaults, triggers).</li>
     * </ul>
     * Los cuatro viajan como GUCs de sesión igual que REQUEST_ID/PATH
     * (ver {@link #wrapWithAuditContext}); HEADERS/REQUEST_BODY
     * llegan ya serializados a JSON así que {@code fn_audit_ctx()} (V26)
     * los castea con {@code ::json} en vez de truncarlos como TEXT.
     */
    private static void injectRequestParams(Map<String, Object> target) {
        if (!(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes sra)) {
            return;
        }
        var req = sra.getRequest();

        // Snapshot ANTES de que este método agregue sus propios
        // CONTEXT.* — así REQUEST_BODY solo refleja lo que trajo el
        // caller (PARAM.*/BODY.*), no metadata derivada por nosotros.
        Map<String, Object> redactedBody = redactSensitiveKeys(target);

        String requestId = req.getHeader("X-Request-Id");
        if (requestId == null || requestId.isBlank()) {
            requestId = UUID.randomUUID().toString();
        } else if (requestId.length() > 100) {
            // El trigger trunca a 100 (ver fn_audit_ctx / LowCardinality en
            // ClickHouse) — cortamos aquí para no mandar ruido de más.
            requestId = requestId.substring(0, 100);
        }
        target.put(ParamNamespace.CONTEXT + ".REQUEST_ID", requestId);

        // Solo la URI — el método va aparte en :CONTEXT.HTTP_METHOD (columna
        // propia de ClickHouse), repetirlo aquí sería redundante.
        target.put(ParamNamespace.CONTEXT + ".PATH", req.getRequestURI());
        target.put(ParamNamespace.CONTEXT + ".HTTP_METHOD", req.getMethod());

        // client_ip: X-Client-Ip (api-gateway's ClientIpGlobalFilter,
        // authoritative) → X-Forwarded-For (unverified, only relevant
        // when NOT behind this gateway) → conexión TCP directa.
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
                headers.put(name.toLowerCase(java.util.Locale.ROOT), value);
            }
        }
        if (!headers.isEmpty()) {
            target.put(ParamNamespace.CONTEXT + ".HEADERS", toJson(headers));
        }

        if (!redactedBody.isEmpty()) {
            target.put(ParamNamespace.CONTEXT + ".REQUEST_BODY", toJson(redactedBody));
        }
    }

    /**
     * V-audit-ctx-2 — el CTE que ANTES vivía como texto literal en
     * {@code public.query.query} (ver el ya-eliminado
     * {@code V80__wrap_write_queries_audit_context.sql}). {@code
     * MATERIALIZED} fuerza a Postgres a computar el CTE (y por tanto
     * ejecutar los {@code set_config}) ANTES de evaluar la subconsulta
     * que llama a la función de escritura real — necesario porque
     * query-service no abre una transacción explícita que abarque más
     * de un statement (cada {@code jdbc.query()} es su propio
     * top-level statement), así que un {@code set_config()} previo en
     * un statement separado no sobreviviría hasta el {@code fn_*} real.
     *
     * <p>Los siete placeholders (:CONTEXT.REQUEST_ID, .HTTP_METHOD,
     * .CLIENT_IP, .USER_AGENT, .HEADERS, .REQUEST_BODY, .PATH) ya están
     * en {@code allParams} para TODA petición gracias a {@link
     * #injectRequestParams} — el wrap es puro texto, no necesita el
     * catálogo para nada.
     *
     * <p>V-audit-ctx-3 — {@code app.user_id}/{@code app.user_pk}: hasta
     * ahora este wrap NUNCA los fijaba (confirmado al auditar este
     * método) — {@code auditoria.audit_log.app_user}/{@code app_user_id}
     * llegaban vacíos para TODA escritura de query-service, no solo las
     * que no pasaban por {@code fn_audit_declarar}. {@code :CONTEXT.USER_ID}
     * (línea ~759, {@code AuthPrincipal.userId()}) es {@code
     * public.users.id_user} — un espacio de ID DISTINTO de {@code
     * academico_test.TUSUARIO.PK_TUSUARIO}, el mismo puente que cada
     * {@code fn_*} de escritura ya usa para {@code
     * p_pk_usuario_solicitante} (ver p.ej. {@code fn_sed_crear} en
     * V64). El CTE {@code _actor} resuelve ese puente UNA vez; {@code
     * app.user_id} usa {@code academico_test.fn_resolver_actor} (V66)
     * para el nombre legible, con el PK crudo como último recurso;
     * {@code app.user_pk} lleva SIEMPRE el PK crudo, nunca pisado por
     * la resolución de nombre — mismo contrato dual que V26/V66.
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
          + "         set_config('app.contexto', jsonb_build_object('path', :CONTEXT.PATH)::text, true) AS _c\n"
          + ")\n"
          + "SELECT _orig.* FROM _ctx, (";

    private static final String AUDIT_CTX_CTE_FOOTER = ") AS _orig";

    /**
     * Detecta una llamada a {@code academico_test.fn_*} en el SQL —
     * la convención de nombres que sigue TODA función de escritura que
     * declara {@code fn_audit_declarar} (ver {@code
     * postgres/migrations/V66__fn_audit_declarar.sql} y las funciones
     * que lo adoptan). Puramente textual y case-insensitive: no
     * requiere mantenimiento cuando se agrega un módulo nuevo (áreas,
     * grados, etc.) — a diferencia del regex por-módulo que usaba el
     * ya-eliminado {@code V80} para generar su lista de {@code
     * id_query}.
     */
    private static final java.util.regex.Pattern ACADEMICO_TEST_FN_CALL =
            java.util.regex.Pattern.compile("academico_test\\.fn_", java.util.regex.Pattern.CASE_INSENSITIVE);

    /**
     * Gate para el wrap automático de contexto de auditoría:
     * <ul>
     *   <li>Solo SELECT/FUNCTION son envolvibles — el truco mete el
     *       SQL original como subconsulta en un FROM, lo que exige
     *       que sea una expresión que devuelve filas. Un {@code
     *       INSERT}/{@code UPDATE} directo (modo DML) o un {@code
     *       CALL} (modo PROCEDURE) no son sintácticamente válidos
     *       ahí — igual que antes de este cambio, esos dos modos se
     *       quedan sin auditoría automática de contexto.</li>
     *   <li>El SQL debe llamar a {@code academico_test.fn_*}
     *       ({@link #ACADEMICO_TEST_FN_CALL}) — sin esto, cualquier
     *       {@code SELECT} de solo lectura con {@code http_method}
     *       distinto de GET (una convención legado real: muchas filas
     *       nunca declararon el verbo y cayeron al default histórico
     *       POST aunque son lecturas puras) recibiría el wrap sin
     *       necesitarlo, rompiendo contra datasources que no son
     *       Postgres/academico_test y agregando trabajo inútil.</li>
     *   <li>{@code httpMethod} nulo cuenta como escritura (POST es el
     *       default histórico de una fila sin verbo declarado — ver
     *       el javadoc de {@link QueryDefinition#httpMethod()}); esto
     *       importa poco en la práctica porque toda función
     *       academico_test.fn_* real ya viene con un verbo explícito,
     *       pero mantiene el gate conservador (envolver de más es
     *       inofensivo, no envolver una escritura real no lo es).</li>
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
     * Headers permitidos en {@code :CONTEXT.HEADERS}. Deliberadamente NO
     * incluye {@code Authorization}/{@code Cookie} — ver el javadoc de
     * {@link #injectRequestParams}. {@code X-Forwarded-For} tampoco está
     * acá porque ya se captura aparte como {@code :CONTEXT.CLIENT_IP}.
     */
    private static final List<String> HEADER_WHITELIST =
            List.of("User-Agent", "Accept-Language", "Referer");

    /**
     * Nombres de placeholder que nunca deben llegar a ClickHouse en texto
     * plano dentro de {@code :CONTEXT.REQUEST_BODY}. Se compara contra el
     * nombre "local" (después del namespace — {@code BODY.PASSWORD} →
     * {@code PASSWORD}), case-insensitive.
     */
    private static final java.util.regex.Pattern SENSITIVE_KEY_PATTERN =
            java.util.regex.Pattern.compile("(?i).*(TOKEN|SECRET|PASSWORD|CONTRASENA|CONTRASEÑA).*");

    private static final com.fasterxml.jackson.databind.ObjectMapper CONTEXT_MAPPER =
            new com.fasterxml.jackson.databind.ObjectMapper();

    /** Copia {@code source} redactando los valores cuyas keys matchean {@link #SENSITIVE_KEY_PATTERN}. */
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
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            log.warn("No se pudo serializar un valor de CONTEXT.* a JSON: {}", e.getMessage());
            return null;
        }
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