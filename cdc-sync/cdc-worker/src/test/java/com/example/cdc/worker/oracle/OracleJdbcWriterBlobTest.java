package com.example.cdc.worker.oracle;

import com.example.cdc.worker.WorkerMetrics;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.io.ByteArrayInputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class OracleJdbcWriterBlobTest {

    @Test
    void mergeWithBlobStreamsBinaryContent() {
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        OracleJdbcWriter writer = new OracleJdbcWriter(jdbc, mock(WorkerMetrics.class));
        Map<String, Object> row = new HashMap<>();
        row.put("PK_TARCHIVO", 1L);
        row.put("CONTENIDO", new ByteArrayInputStream("PDF".getBytes()));
        row.put("URL", "/file.pdf");
        row.put("URLS3", "s3://bucket/file.pdf");

        writer.mergeWithBlob("TARCHIVO", "PK_TARCHIVO", row, List.of("CONTENIDO"));

        verify(jdbc).update(Mockito.contains("MERGE INTO TARCHIVO"), any(MapSqlParameterSource.class));
    }
}