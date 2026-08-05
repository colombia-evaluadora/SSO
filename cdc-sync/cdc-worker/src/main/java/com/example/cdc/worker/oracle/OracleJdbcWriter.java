package com.example.cdc.worker.oracle;

import com.example.cdc.worker.WorkerMetrics;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Component
public class OracleJdbcWriter {

    private final NamedParameterJdbcTemplate jdbc;
    private final WorkerMetrics workerMetrics;

    public OracleJdbcWriter(NamedParameterJdbcTemplate jdbc, WorkerMetrics workerMetrics) {
        this.jdbc = jdbc;
        this.workerMetrics = workerMetrics;
    }

    public void merge(String oracleTable, String pkColumn, Map<String, Object> row) {
        if (row == null || row.isEmpty()) return;

        List<String> cols = new ArrayList<>(row.keySet());
        cols.remove(pkColumn);

        // Short-circuit: only the PK itself was supplied. The templated MERGE
        // below cannot build a valid UPDATE SET or comma-separated INSERT list,
        // so use the dedicated PK-only no-op MERGE for idempotent CDC replays.
        if (cols.isEmpty()) {
            insertPkOnly(oracleTable, pkColumn, row.get(pkColumn));
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

        MapSqlParameterSource params = new MapSqlParameterSource();
        for (Map.Entry<String, Object> e : row.entrySet()) {
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

        List<String> nonBlobCols = row.keySet().stream()
                .filter(c -> !blobColumns.contains(c))
                .toList();

        // Short-circuit: only the PK itself was supplied. Use the same idempotent
        // PK-only no-op MERGE as merge() so CDC replays stay idempotent.
        if (nonBlobCols.isEmpty()) {
            insertPkOnly(oracleTable, pkColumn, row.get(pkColumn));
            return;
        }

        String setClause = nonBlobCols.stream()
                .filter(c -> !c.equalsIgnoreCase(pkColumn))
                .map(c -> "t." + c + " = src." + c)
                .collect(Collectors.joining(", "));

        String insertCols = String.join(", ", nonBlobCols);
        String insertVals = nonBlobCols.stream().map(c -> "src." + c).collect(Collectors.joining(", "));
        String selectCols = nonBlobCols.stream()
                .map(c -> ":" + c + " AS " + c)
                .collect(Collectors.joining(", "));

        String sql = "MERGE INTO " + oracleTable + " t USING (SELECT " + selectCols +
                " FROM DUAL) src ON (t." + pkColumn + " = src." + pkColumn + ")" +
                " WHEN MATCHED THEN UPDATE SET " + setClause +
                " WHEN NOT MATCHED THEN INSERT (" + pkColumn + ", " + insertCols + ") VALUES (src." + pkColumn + ", " + insertVals + ")";

        MapSqlParameterSource params = new MapSqlParameterSource();
        for (Map.Entry<String, Object> e : row.entrySet()) {
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
}