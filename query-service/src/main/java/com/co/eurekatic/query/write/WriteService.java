package com.co.eurekatic.query.write;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.WriteDefinition;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.web.WriteRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
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
 *   <li>Validate the request — the {@code columns} map must
 *       cover EXACTLY the declared column list, no more,
 *       no less. {@code keyColumns} must be present for
 *       UPDATE.</li>
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

    public WriteService(CatalogClient catalog, JdbcTemplateRegistry registry) {
        this.catalog = catalog;
        this.registry = registry;
    }

    /**
     * Executes the write. Returns the number of rows
     * affected (1 for INSERT, 0..N for UPDATE).
     */
    public int execute(WriteRequest req) {
        Authentication auth = currentAuthentication();
        WriteDefinition def = catalog.fetchWrite(bearerToken(auth), req.uuid());

        // 1. Strict shape check — every declared column must
        //    be present, and no undeclared keys may slip
        //    through. We iterate the declared list (not the
        //    request map) so an attacker can't smuggle in
        //    extra keys that happen to be ignored by the
        //    INSERT.
        for (String declared : def.columns()) {
            if (!req.columns().containsKey(declared)) {
                throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                        "Missing column: " + declared);
            }
        }
        for (String submitted : req.columns().keySet()) {
            if (!def.columns().contains(submitted)) {
                throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                        "Unknown column: " + submitted);
            }
        }

        // 2. Build the SQL. Column names come from
        //    def.columns() (catalog), values come from the
        //    bound parameter map. The :placeholder tokens
        //    are derived from the declared column list, NOT
        //    from the request.
        NamedParameterJdbcTemplate jdbc = registry.resolve(/* type */ null);
        // Note: WriteDefinition doesn't carry TYPE; we
        // route via a system-wide default. For v1, writes
        // always go through the default-configured dialect.
        // A future iteration would extend WriteDefinition
        // with a TYPE column.

        String sql;
        if (def.isInsert()) {
            sql = buildInsert(def);
        } else if (def.isUpdate()) {
            sql = buildUpdate(def);
        } else {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Unsupported write type: " + def.writeType());
        }

        MapSqlParameterSource params = new MapSqlParameterSource(req.columns());
        int rows = jdbc.update(sql, params);
        log.info("Write uuid={} ({}) affected {} rows", req.uuid(), def.writeType(), rows);
        return rows;
    }

    /**
     * Builds an {@code INSERT INTO <table> (col1, col2, ...)
     * VALUES (:col1, :col2, ...)} statement. The column
     * names are pinned by the catalog definition.
     */
    private static String buildInsert(WriteDefinition def) {
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
                    "UPDATE requires keyColumns");
        }
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
                    "No authenticated principal");
        }
        return auth;
    }

    private static String bearerToken(Authentication auth) {
        Object creds = auth.getCredentials();
        if (!(creds instanceof String s) || s.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "Missing bearer token in security context");
        }
        return s;
    }

    /**
     * Helper for tests — exposes the SQL builder output.
     */
    static String buildInsertSqlForTest(WriteDefinition def) { return buildInsert(def); }
    static String buildUpdateSqlForTest(WriteDefinition def) { return buildUpdate(def); }
}