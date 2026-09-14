package com.co.eurekatic.query.write;

import com.co.eurekatic.common.query.SqlIdentifiers;
import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.WriteDefinition;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.exception.PostgresErrorMapper;
import com.co.eurekatic.query.observability.QueryMetrics;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.routing.CatalogResultCacheService;
import com.co.eurekatic.query.web.WriteRequest;
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

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Write-path business logic. The flow:
 *
 * <ol>
 *   <li>Resolve the uuid via the catalog (same auth path as
 *       the read side).</li>
 *   <li>Validate the request — every declared column must be
 *       present in the {@code columns} map. Keys the catalog
 *       doesn't declare are ignored: the SQL is built from the
 *       declared list, so they never reach the statement.</li>
 *   <li>Build a parameterised statement. We never build SQL
 *       by string-concatenating column names; the catalog's
 *       declared list is the source of truth, and it goes
 *       into the SQL verbatim, but values come from the
 *       bound parameter map.</li>
 *   <li>Execute via the dialect-specific
 *       {@link NamedParameterJdbcTemplate}.</li>
 * </ol>
 *
 * <p><b>Hard rules this class enforces</b>:
 * <ul>
 *   <li>Column names from the request: NEVER. Only values
 *       (the {@code columns} map keys are checked against
 *       the catalog list, but they are NOT used to build
 *       the SQL).</li>
 *   <li>Table names from the request: NEVER. The catalog
 *       carries the table name and we trust the catalog
 *       authorization check (only admins with the right
 *       role can bind a WriteDefinition).</li>
 *   <li>DDL: NEVER. INSERT and UPDATE are the only allowed
 *       write types; CREATE TABLE / CREATE PROCEDURE / etc.
 *       are explicitly disallowed by the catalog's enum.</li>
 * </ul>
 */
@Service
public class WriteService {

    private static final Logger log = LoggerFactory.getLogger(WriteService.class);

    private final CatalogClient catalog;
    private final JdbcTemplateRegistry registry;
    private final CatalogResultCacheService resultCache;
    private final QueryResilience resilience;
    private final QueryMetrics metrics;

    public WriteService(CatalogClient catalog, JdbcTemplateRegistry registry,
                        CatalogResultCacheService resultCache,
                        QueryResilience resilience, QueryMetrics metrics) {
        this.catalog = catalog;
        this.registry = registry;
        this.resultCache = resultCache;
        this.resilience = resilience;
        this.metrics = metrics;
    }

    /**
     * Executes the write. Returns the number of rows affected (1 for
     * INSERT, 0..N for UPDATE).
     *
     * <p>Goes through the same bulkhead and the same execution metric as
     * the read path: a write holds a pooled connection exactly like a read
     * does, so leaving it uncapped meant the one operation that also takes
     * row locks was the one with no limit on how many could run at once.
     */
    public int execute(WriteRequest req) {
        long start = System.nanoTime();
        try {
            int rows = doExecute(req);
            metrics.recordExecution("WRITE", QueryMetrics.Outcome.SUCCESS,
                    System.nanoTime() - start);
            return rows;
        } catch (RuntimeException e) {
            metrics.recordExecution("WRITE", QueryMetrics.Outcome.FAILURE,
                    System.nanoTime() - start);
            throw e;
        }
    }

    private int doExecute(WriteRequest req) {
        Authentication auth = currentAuthentication();
        WriteDefinition def = catalog.fetchWrite(bearerToken(auth), req.uuid());

        // 1. Shape check — every declared column must be present
        //    (case-insensitive: the catalog may declare it in
        //    MAYÚSCULAS and the client send it in lowercase). Keys
        //    the catalog doesn't declare are ignored: the SQL below
        //    is built from def.columns(), never from the request,
        //    so an extra key can't reach the statement.
        java.util.Set<String> declaredLower = new java.util.HashSet<>();
        for (String c : def.columns()) declaredLower.add(c.toLowerCase(java.util.Locale.ROOT));
        List<String> ignored = req.columns().keySet().stream()
                .filter(k -> !declaredLower.contains(k.toLowerCase(java.util.Locale.ROOT)))
                .toList();
        if (!ignored.isEmpty()) {
            log.debug("Write uuid={} ignora columnas no declaradas: {}", req.uuid(), ignored);
        }
        for (String declared : def.columns()) {
            boolean present = req.columns().keySet().stream()
                    .anyMatch(k -> k.equalsIgnoreCase(declared));
            if (!present) {
                throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                        "Falta la columna: " + declared);
            }
        }

        // 2. Build the SQL. Column names come from def.columns()
        //    (catalog), values from the bound parameter map.
        //    WriteDefinition doesn't carry TYPE, so writes always
        //    go through the default-configured dialect.
        NamedParameterJdbcTemplate jdbc = registry.resolve(/* type */ null);

        String sql;
        if (def.isInsert()) {
            sql = buildInsert(def);
        } else if (def.isUpdate()) {
            sql = buildUpdate(def);
        } else {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Tipo de escritura no soportado: " + def.writeType());
        }

        // El SQL usa los nombres del catálogo (normalmente en
        // MAYÚSCULAS) y Spring JDBC matchea placeholders
        // case-sensitively, así que cada valor se publica bajo la
        // key original del cliente Y bajo su forma en MAYÚSCULAS.
        java.util.Map<String, Object> normalizedColumns =
                new java.util.LinkedHashMap<>(req.columns());
        for (java.util.Map.Entry<String, Object> e : req.columns().entrySet()) {
            String upper = e.getKey().toUpperCase(java.util.Locale.ROOT);
            if (!upper.equals(e.getKey())) {
                normalizedColumns.putIfAbsent(upper, e.getValue());
            }
        }
        MapSqlParameterSource params = new MapSqlParameterSource(normalizedColumns);

        // Writes always land on the default dialect (WriteDefinition has no
        // TYPE column), so they share that dialect's bulkhead with the reads
        // that target it — which is the point: they compete for the same
        // Hikari pool.
        var bulkhead = resilience.bulkheadFor("default");
        if (!bulkhead.tryAcquirePermission()) {
            throw BulkheadFullException.createBulkheadFullException(bulkhead);
        }
        int rows;
        try {
            rows = jdbc.update(sql, params);
        } catch (DataAccessException dae) {
            throw PostgresErrorMapper.map(dae);
        } finally {
            bulkhead.onComplete();
        }
        log.info("Write uuid={} ({}) affected {} rows", req.uuid(), def.writeType(), rows);
        // A WriteDefinition carries a table name but no path template, and
        // cache entries are tagged by path resource — there is nothing to
        // match a table against, so the only correct scope is everything
        // this instance cached.
        resultCache.invalidateAll();
        return rows;
    }

    /**
     * Comprueba que la tabla y las columnas que trae el catálogo son
     * identificadores SQL antes de interpolarlos en
     * {@link #buildInsert} / {@link #buildUpdate}. "Viene del
     * catálogo" no es lo mismo que "es seguro interpolarlo": una fila
     * corrupta o un bug en el formulario que la crea bastan para meter
     * texto arbitrario en la sentencia.
     *
     * <p>Es un 500 y no un 400 a propósito: el caller no controla
     * estos valores, así que no hay nada que pueda corregir en su
     * petición.
     */
    private static void validarIdentificadores(WriteDefinition def) {
        try {
            SqlIdentifiers.exigirTabla(def.tableName(), "El nombre de tabla del catálogo");
            for (String c : def.columns()) {
                SqlIdentifiers.exigirSimple(c, "La columna del catálogo");
            }
            if (def.keyColumns() != null) {
                for (String c : def.keyColumns()) {
                    SqlIdentifiers.exigirSimple(c, "La columna clave del catálogo");
                }
            }
        } catch (IllegalArgumentException e) {
            log.error("WriteDefinition uuid={} con identificadores inválidos: {}",
                    def.uuid(), e.getMessage());
            throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR,
                    "La definición de escritura del catálogo no es válida");
        }
    }

    /**
     * Builds an {@code INSERT INTO <table> (col1, col2, ...)
     * VALUES (:col1, :col2, ...)} statement. The column
     * names are pinned by the catalog definition.
     */
    private static String buildInsert(WriteDefinition def) {
        validarIdentificadores(def);
        List<String> cols = def.columns();
        StringBuilder colsSql = new StringBuilder();
        StringBuilder valsSql = new StringBuilder();
        for (int i = 0; i < cols.size(); i++) {
            if (i > 0) { colsSql.append(','); valsSql.append(','); }
            colsSql.append(cols.get(i));
            valsSql.append(':').append(cols.get(i));
        }
        return "INSERT INTO " + def.tableName() + " (" + colsSql + ") VALUES (" + valsSql + ")";
    }

    /**
     * Builds an {@code UPDATE <table> SET col1 = :col1,
     * ... WHERE key1 = :key1 AND key2 = :key2} statement.
     */
    private static String buildUpdate(WriteDefinition def) {
        List<String> keyCols = def.keyColumns();
        if (keyCols == null || keyCols.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "UPDATE requiere keyColumns");
        }
        validarIdentificadores(def);
        List<String> updateCols = new ArrayList<>(def.columns());
        updateCols.removeAll(keyCols);

        StringBuilder setSql = new StringBuilder();
        for (int i = 0; i < updateCols.size(); i++) {
            if (i > 0) setSql.append(',');
            setSql.append(updateCols.get(i)).append(" = :").append(updateCols.get(i));
        }
        StringBuilder whereSql = new StringBuilder();
        for (int i = 0; i < keyCols.size(); i++) {
            if (i > 0) whereSql.append(" AND ");
            whereSql.append(keyCols.get(i)).append(" = :").append(keyCols.get(i));
        }
        return "UPDATE " + def.tableName() + " SET " + setSql + " WHERE " + whereSql;
    }

    private static Authentication currentAuthentication() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !(auth.getPrincipal() instanceof AuthPrincipal)) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "No hay un principal autenticado");
        }
        return auth;
    }

    private static String bearerToken(Authentication auth) {
        Object creds = auth.getCredentials();
        if (!(creds instanceof String s) || s.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "Falta el token bearer en el contexto de seguridad");
        }
        return s;
    }

    /**
     * Helper for tests — exposes the SQL builder output.
     */
    static String buildInsertSqlForTest(WriteDefinition def) { return buildInsert(def); }
    static String buildUpdateSqlForTest(WriteDefinition def) { return buildUpdate(def); }
}