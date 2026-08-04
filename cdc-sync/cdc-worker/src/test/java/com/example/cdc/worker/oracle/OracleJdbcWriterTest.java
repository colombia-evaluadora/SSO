package com.example.cdc.worker.oracle;

import com.example.cdc.worker.WorkerMetrics;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.Map;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class OracleJdbcWriterTest {

    @Test
    void builds_merge_sql_and_executes() {
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        OracleJdbcWriter writer = new OracleJdbcWriter(jdbc, mock(WorkerMetrics.class));

        writer.merge("CLIENTES", "PK_CLIENTE",
                Map.of("PK_CLIENTE", 1, "NOMBRE", "Alice", "SALDO", 100.50));

        verify(jdbc).update(anyString(), any(MapSqlParameterSource.class));
    }

    @Test
    void merge_with_pk_only_short_circuits_to_insert_pk_only() {
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        OracleJdbcWriter writer = new OracleJdbcWriter(jdbc, mock(WorkerMetrics.class));

        // PK-only row (no non-PK columns) — must produce an idempotent MERGE
        // rather than a plain INSERT, so CDC replays do not raise ORA-00001.
        writer.merge("CLIENTES", "PK_CLIENTE", Map.of("PK_CLIENTE", 7));

        verify(jdbc).update(eq("MERGE INTO CLIENTES tab USING (SELECT :PK_CLIENTE AS PK_CLIENTE FROM DUAL) src ON (tab.PK_CLIENTE = src.PK_CLIENTE) WHEN NOT MATCHED THEN INSERT (PK_CLIENTE) VALUES (src.PK_CLIENTE)"),
                any(MapSqlParameterSource.class));
    }

    @Test
    void delete_executes_simple_sql() {
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        OracleJdbcWriter writer = new OracleJdbcWriter(jdbc, mock(WorkerMetrics.class));

        writer.delete("CLIENTES", "PK_CLIENTE", 1);

        verify(jdbc).update(eq("DELETE FROM CLIENTES WHERE PK_CLIENTE = :PK_CLIENTE"),
                any(MapSqlParameterSource.class));
    }
}