package com.example.cdc.worker.oracle;

import com.example.cdc.worker.WorkerMetrics;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

@Component
public class OracleJdbcWriter {

    private static final Logger log = LoggerFactory.getLogger(OracleJdbcWriter.class);

    private final NamedParameterJdbcTemplate jdbc;
    private final WorkerMetrics workerMetrics;

    /**
     * Per-table cache of column-name → Oracle {@code java.sql.Types} code,
     * populated lazily on the first {@link #merge(String, String, Map)} call
     * for each table by reading {@link java.sql.DatabaseMetaData#getColumns}.
     * Without this map, Spring's
     * {@code StatementCreatorUtils.setNull(parameterIndex, sqlType)} would
     * be called with {@code sqlType = Integer.MIN_VALUE + 1}
     * (the {@code TYPE_UNKNOWN} sentinel from
     * {@code MapSqlParameterSource#getSqlType(String)}) and the Oracle
     * thin driver rejects it with
     * {@code ORA-17004: Invalid column type: 268435455} — every time a
     * transformer emits a nullable foreign key (e.g.
     * {@code TGrupoFkRewriter} before the snapshot cache is hydrated, or
     * {@code TMATRICULA} snapshot columns that legitimately resolve to
     * null). The cache turns each table's column-metadata read into a
     * one-shot cost; subsequent merges hit a {@link HashMap#get}
     * without opening a JDBC connection.
     *
     * <p>Upper-cased keys on both sides — Oracle stores identifiers in
     * upper case by default, and the transformer row dict is upper-cased
     * by the L4-L6 phase-3 routing.
     */
    private final Map<String, Map<String, Integer>> columnTypeCache = new ConcurrentHashMap<>();

    public OracleJdbcWriter(NamedParameterJdbcTemplate jdbc, WorkerMetrics workerMetrics) {
        this.jdbc = jdbc;
        this.workerMetrics = workerMetrics;
    }

    public void merge(String oracleTable, String pkColumn, Map<String, Object> row) {
        if (row == null || row.isEmpty()) return;

        // Pre-process the row so each value matches the JDBC type Oracle expects.
        // Without this, Debezium's epoch-millis Long carries through unchanged
        // and the Oracle driver raises ORA-17132 ("Invalid conversion
        // requested: java.lang.Long to oracle.sql.TIMESTAMP") for every
        // created_at / modified_at cell. Consult the column-type cache for
        // the actual JDBC type codes (TIMESTAMP/DATE/etc.) and pre-convert.
        Map<String, Object> coerced = coerceRow(oracleTable, row);

        List<String> cols = new ArrayList<>(coerced.keySet());
        cols.remove(pkColumn);

        // Short-circuit: only the PK itself was supplied. The templated MERGE
        // below cannot build a valid UPDATE SET or comma-separated INSERT list,
        // so use the dedicated PK-only no-op MERGE for idempotent CDC replays.
        if (cols.isEmpty()) {
            insertPkOnly(oracleTable, pkColumn, coerced.get(pkColumn));
            return;
        }

        String updateSet = cols.stream()
                .map(c -> "tab." + c + " = src." + c)
                .collect(Collectors.joining(", "));

        String insertCols = String.join(", ", cols);
        String insertVals = cols.stream().map(c -> "src." + c).collect(Collectors.joining(", "));

        String sql = String.format("""
            MERGE INTO %s tab
            USING (SELECT :%s AS %s%s) src
            ON (tab.%s = src.%s)
            WHEN MATCHED THEN UPDATE SET %s
            WHEN NOT MATCHED THEN INSERT (%s, %s) VALUES (src.%s, %s)
            """,
            oracleTable,
            pkColumn, pkColumn,
            cols.isEmpty() ? "" : ", " + cols.stream().map(c -> ":" + c + " AS " + c).collect(Collectors.joining(", ")),
            pkColumn, pkColumn,
            updateSet,
            pkColumn, insertCols,
            pkColumn, insertVals
        );

        MapSqlParameterSource params = new MapSqlParameterSource() {
            // See class javadoc on the column-type cache: override Spring's
            // TYPE_UNKNOWN so null binds use a real Oracle sqlType code.
            @Override
            public int getSqlType(String paramName) {
                if (paramName == null) return java.sql.Types.NULL;
                return sqlTypeFor(oracleTable, paramName.toUpperCase());
            }
        };
        for (Map.Entry<String, Object> e : coerced.entrySet()) {
            params.addValue(e.getKey(), e.getValue());
        }

        long start = System.nanoTime();
        try {
            jdbc.update(sql, params);
        } finally {
            long millis = (System.nanoTime() - start) / 1_000_000;
            workerMetrics.recordOracleMerge(millis);
        }
    }

    /**
     * No-op MERGE used by {@link #merge} when the incoming row contains only
     * the PK (no non-PK columns to MERGE on). Implemented as a MERGE so the
     * operation is idempotent under CDC at-least-once delivery: replays on an
     * INSERT hit the WHEN NOT MATCHED branch only on the first delivery; on
     * subsequent replays the row already exists and the MERGE no-ops. A plain
     * INSERT would raise ORA-00001 (unique constraint violation), burn retries,
     * and dead-letter the event.
     */
    private void insertPkOnly(String oracleTable, String pkColumn, Object pkValue) {
        String sql = String.format(
                "MERGE INTO %s tab USING (SELECT :%s AS %s FROM DUAL) src ON (tab.%s = src.%s) "
                        + "WHEN NOT MATCHED THEN INSERT (%s) VALUES (src.%s)",
                oracleTable, pkColumn, pkColumn, pkColumn, pkColumn, pkColumn, pkColumn);
        MapSqlParameterSource params = new MapSqlParameterSource(pkColumn, pkValue);
        long start = System.nanoTime();
        try {
            jdbc.update(sql, params);
        } finally {
            long millis = (System.nanoTime() - start) / 1_000_000;
            workerMetrics.recordOracleMerge(millis);
        }
    }

    public void delete(String oracleTable, String pkColumn, Object pkValue) {
        String sql = String.format("DELETE FROM %s WHERE %s = :%s", oracleTable, pkColumn, pkColumn);
        MapSqlParameterSource params = new MapSqlParameterSource(pkColumn, pkValue);
        jdbc.update(sql, params);
    }

    /**
     * Typed INSERT path used by the AUTO_SPLIT rewrite in
     * {@link com.example.cdc.worker.pipeline.OracleReverseStage#executeAutoSplit}.
     * Same machinery as {@link #merge(String, String, Map)} (coerced values +
     * {@code getSqlType} override that drives Long→Timestamp for
     * {@code created_at} / {@code modified_at}, etc.) but emits a plain
     * INSERT instead of a MERGE. The {@code pkColumn} key in {@code row} is
     * passed through; when present it's a previously-resolved Oracle PK
     * (used by re-runs), and the SQL uses it as the literal PK value.
     */
    public void insertTyped(String oracleTable, String pkColumn, Map<String, Object> row) {
        if (row == null || row.isEmpty()) return;

        // Coerce epoch-millis Long → Timestamp via the column-type cache.
        Map<String, Object> coerced = coerceRow(oracleTable, row);
        List<String> cols = new ArrayList<>(coerced.keySet());

        String vals = cols.stream().map(c -> ":" + c).collect(Collectors.joining(", "));

        String sql = String.format("INSERT INTO %s (%s) VALUES (%s)",
            oracleTable,
            cols.stream().map(String::toUpperCase).collect(Collectors.joining(", ")),
            vals);

        MapSqlParameterSource params = new MapSqlParameterSource() {
            @Override
            public int getSqlType(String paramName) {
                if (paramName == null) return java.sql.Types.NULL;
                return sqlTypeFor(oracleTable, paramName.toUpperCase());
            }
        };
        for (Map.Entry<String, Object> e : coerced.entrySet()) {
            params.addValue(e.getKey(), e.getValue());
        }

        long start = System.nanoTime();
        try {
            jdbc.update(sql, params);
        } finally {
            long millis = (System.nanoTime() - start) / 1_000_000;
            workerMetrics.recordOracleMerge(millis);
        }
    }

    /**
     * Variant of {@link #merge} that supports streaming BLOBs through Oracle.
     * <p>
     * Used by {@code TArchivoBlobDropper} (see spec section 3.6) to persist the
     * {@code CONTENIDO} column on {@code TARCHIVO}: the value for each column
     * listed in {@code blobColumns} is passed through {@link MapSqlParameterSource#addValue}
     * unchanged, which lets Spring bind an {@link java.io.InputStream} via the
     * JDBC {@code setBinaryStream(...)} path against an Oracle {@code BLOB}
     * column. All other columns are bound through the regular JDBC type
     * resolution.
     * <p>
     * The MERGE shape mirrors {@link #merge}: an idempotent
     * {@code WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT ...}
     * keyed on {@code pkColumn}, so CDC at-least-once replays do not raise
     * ORA-00001.
     *
     * @param oracleTable target Oracle table (already upper-cased by the caller).
     * @param pkColumn     primary-key column name (used for the {@code ON} clause).
     * @param row          full row map including BLOB column values.
     * @param blobColumns  column names whose values are streamed as BLOBs.
     */
    public void mergeWithBlob(String oracleTable, String pkColumn, Map<String, Object> row, List<String> blobColumns) {
        if (row == null || row.isEmpty()) return;

        // Strip BOTH the PK and any BLOB columns. The PK is the ON-clause key
        // so it lives in the SELECT/USING side but must NOT appear in the
        // INSERT column list (Oracle ORA-00957 on duplicate column names).
        // BLOB columns are bound via setBinaryStream and live outside the
        // generated UPDATE/INSERT fragments.
        List<String> nonBlobCols = row.keySet().stream()
                .filter(c -> !blobColumns.contains(c))
                .filter(c -> !c.equalsIgnoreCase(pkColumn))
                .toList();

        // Short-circuit: every column was either the PK or a BLOB. Use the
        // same idempotent PK-only no-op MERGE as merge() so CDC replays stay
        // idempotent.
        if (nonBlobCols.isEmpty()) {
            insertPkOnly(oracleTable, pkColumn, row.get(pkColumn));
            return;
        }

        String setClause = nonBlobCols.stream()
                .map(c -> "t." + c + " = src." + c)
                .collect(Collectors.joining(", "));
        String insertCols = String.join(", ", nonBlobCols);
        String insertVals = nonBlobCols.stream().map(c -> "src." + c).collect(Collectors.joining(", "));

        // SELECT clause carries EVERY named placeholder — PK + non-PK + blobs —
        // so all `:col` binds resolve. Only the INSERT column list (above)
        // excludes the PK.
        String selectCols = row.keySet().stream()
                .map(c -> ":" + c + " AS " + c)
                .collect(Collectors.joining(", "));

        String sql = "MERGE INTO " + oracleTable + " t USING (SELECT " + selectCols +
                " FROM DUAL) src ON (t." + pkColumn + " = src." + pkColumn + ")" +
                " WHEN MATCHED THEN UPDATE SET " + setClause +
                " WHEN NOT MATCHED THEN INSERT (" + insertCols + ") VALUES (" + insertVals + ")";

        MapSqlParameterSource params = new MapSqlParameterSource() {
            @Override
            public int getSqlType(String paramName) {
                if (paramName == null) return java.sql.Types.NULL;
                return sqlTypeFor(oracleTable.toUpperCase(), paramName.toUpperCase());
            }
        };
        // Coerce epoch-millis Longs → Timestamp where Oracle expects TIMESTAMP
        // (a Debezium-Postgres quirk for `created_at` etc.). BLOB InputStream
        // entries are returned as-is by coerceValue() so setBinaryStream still
        // gets the original blob stream. The mergeWithBlob path therefore
        // needs no extra defensive code beyond the same coerceRow() call.
        Map<String, Object> coerced = coerceRow(oracleTable, row);
        for (Map.Entry<String, Object> e : coerced.entrySet()) {
            // InputStream values for blobColumns flow through MapSqlParameterSource
            // unchanged; Spring's NamedParameterJdbcTemplate binds them via
            // setBinaryStream() against the target BLOB column.
            params.addValue(e.getKey(), e.getValue());
        }

        long start = System.nanoTime();
        try {
            jdbc.update(sql, params);
        } finally {
            long millis = (System.nanoTime() - start) / 1_000_000;
            workerMetrics.recordOracleMerge(millis);
        }
    }

    /**
     * Returns the {@link java.sql.Types} code for {@code colName}
     * (already upper-cased by the caller) in {@code oracleTable}
     * (already upper-cased). Falls back to {@link java.sql.Types#NULL}
     * if either the table metadata is not yet cached or the column is
     * genuinely unknown — Spring then issues {@code setNull(idx,
     * Types.NULL)}, which the Oracle thin driver accepts as a
     * generic NULL placeholder. The first call for each table opens
     * a JDBC connection to {@link DatabaseMetaData#getColumns}; every
     * subsequent call is an in-memory {@link Map#get}.
     */
    private int sqlTypeFor(String oracleTableUpper, String colNameUpper) {
        Map<String, Integer> perTable = columnTypeCache.computeIfAbsent(
                oracleTableUpper, this::loadColumnTypes);
        Integer t = perTable.get(colNameUpper);
        return t != null ? t : java.sql.Types.NULL;
    }

    /**
     * Reads column metadata for {@code oracleTable} via JDBC
     * {@link DatabaseMetaData#getColumns}. Returns an empty map (and
     * logs a WARN) on any error so that merges can still proceed
     * with the {@link java.sql.Types#NULL} fallback rather than
     * crashing the worker for one transient metadata hiccup.
     */
    private Map<String, Integer> loadColumnTypes(String oracleTableUpper) {
        Map<String, Integer> result = new HashMap<>();
        DataSource ds = jdbc.getJdbcTemplate().getDataSource();
        if (ds == null) {
            log.warn("No DataSource available for column-type lookup; {} will fall back to Types.NULL", oracleTableUpper);
            return result;
        }
        try (Connection conn = ds.getConnection()) {
            String schema = conn.getMetaData().getUserName();
            try (ResultSet rs = conn.getMetaData().getColumns(null, schema, oracleTableUpper, null)) {
                while (rs.next()) {
                    String name = rs.getString("COLUMN_NAME");
                    int type = rs.getInt("DATA_TYPE");
                    if (name != null) {
                        result.put(name.toUpperCase(), type);
                    }
                }
            }
            if (result.isEmpty()) {
                log.warn("Column metadata returned 0 rows for table {} (schema={}); all binds will fall back to Types.NULL", oracleTableUpper, schema);
            } else {
                log.debug("Cached {} column types for table {}", result.size(), oracleTableUpper);
            }
        } catch (SQLException e) {
            log.warn("Failed to load column types for {} — falling back to Types.NULL on every bind: {}",
                    oracleTableUpper, e.getMessage());
        }
        return result;
    }

    /**
     * Builds a new row map whose keys are restricted to the columns Oracle
     * actually exposes for {@code oracleTableUpper}. Drops PG-only fields
     * (e.g. {@code pk_lista_valor}, {@code categoria}, {@code active},
     * {@code accion}) so the AUTO_SPLIT INSERT only references columns that
     * exist on the cat_eliminadas side. Returns a mutator-in place; safe to
     * call with the live cache because we only consult {@link #columnTypeCache}.
     *
     * <p>This is the fix for the ORA-00904 caused by {@link com.example.cdc.worker.pipeline.OracleReverseStage#executeAutoSplit}
     * attempting to insert a full PG tlista_valor row into a stripped-down
     * Oracle cat_eliminada.
     *
     * @param oracleTableUpper case-correct Oracle table name (will be upper-cased defensively)
     * @param sourceRow the source row from {@code TlistaValorSplitter} or {@code merge()}
     * @return a LinkedHashMap preserving insertion order, containing only keys that exist as columns in Oracle
     */
    public Map<String, Object> filterToTableColumns(String oracleTableUpper, Map<String, Object> sourceRow) {
        String upper = oracleTableUpper.toUpperCase();
        Map<String, Integer> cols = columnTypeCache.computeIfAbsent(upper, this::loadColumnTypes);
        Map<String, Object> filtered = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : sourceRow.entrySet()) {
            String keyUpper = e.getKey() == null ? "" : e.getKey().toUpperCase();
            if (cols.containsKey(keyUpper)) {
                filtered.put(e.getKey(), e.getValue());
            }
        }
        return filtered;
    }

    /**
     * Convenience that maps {@code sourceRow[valor]} into the Oracle
     * {@code CODIGO} column (since Oracle cat_eliminadas name the codigo
     * column {@code CODIGO}) before filtering through
     * {@link #filterToTableColumns}. The {@code valor}→{@code CODIGO}
     * aliasing was previously implicit in the AUTO_SPLIT path; exposing
     * it here keeps the projection single-pass and side-effect free.
     */
    public Map<String, Object> buildInsertableRow(String oracleTableUpper,
                                                 Map<String, Object> sourceRow,
                                                 Object valor) {
        Map<String, Object> work = new LinkedHashMap<>(sourceRow);
        if (valor != null) {
            work.put("CODIGO", valor);
        }
        return filterToTableColumns(oracleTableUpper, work);
    }

    /**
     * Pre-coerces the row so each value matches the JDBC type Oracle expects
     * for that column. Today the only coercion needed is
     * epoch-millis {@code Long} → {@link java.sql.Timestamp} (and similarly
     * for {@code DATE}); the column-type cache drives the lookup. Returns
     * a LinkedHashMap preserving source order so MERGE INSERT/UPDATE column
     * lists stay predictable.
     */
    private Map<String, Object> coerceRow(String oracleTableUpper, Map<String, Object> sourceRow) {
        String upper = oracleTableUpper.toUpperCase();
        Map<String, Integer> cols = columnTypeCache.computeIfAbsent(upper, this::loadColumnTypes);
        Map<String, Object> out = new LinkedHashMap<>(sourceRow.size());
        for (Map.Entry<String, Object> e : sourceRow.entrySet()) {
            String keyUpper = e.getKey() == null ? "" : e.getKey().toUpperCase();
            Integer sqlType = cols.get(keyUpper);
            out.put(e.getKey(), coerceValue(e.getValue(), sqlType));
        }
        return out;
    }

    private static Object coerceValue(Object value, Integer sqlType) {
        if (value == null || sqlType == null) return value;
        if (value instanceof java.io.InputStream || value instanceof java.sql.Timestamp) {
            return value;
        }
        switch (sqlType) {
            case java.sql.Types.TIMESTAMP:
            case java.sql.Types.TIMESTAMP_WITH_TIMEZONE:
                if (value instanceof Long l) return new java.sql.Timestamp(l);
                if (value instanceof Integer i) return new java.sql.Timestamp(i.longValue());
                if (value instanceof java.util.Date d) return new java.sql.Timestamp(d.getTime());
                break;
            case java.sql.Types.DATE:
                if (value instanceof Long l) return new java.sql.Date(l);
                if (value instanceof Integer i) return new java.sql.Date(i.longValue());
                if (value instanceof java.util.Date d) return new java.sql.Date(d.getTime());
                break;
            case java.sql.Types.NUMERIC:
            case java.sql.Types.DECIMAL:
                if (value instanceof Boolean b) return b ? 1 : 0;
                break;
            default:
                break;
        }
        return value;
    }
}