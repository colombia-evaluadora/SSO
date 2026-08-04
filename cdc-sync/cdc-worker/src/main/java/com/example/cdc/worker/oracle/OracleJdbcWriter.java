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
}