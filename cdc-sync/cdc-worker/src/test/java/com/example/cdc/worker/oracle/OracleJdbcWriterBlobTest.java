package com.example.cdc.worker.oracle;

import com.example.cdc.worker.WorkerMetrics;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class OracleJdbcWriterBlobTest {

    @Test
    void mergeWithBlobStreamsBinaryContent() {
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        OracleJdbcWriter writer = new OracleJdbcWriter(jdbc, mock(WorkerMetrics.class));
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("PK_TARCHIVO", 1L);
        row.put("URL", "/file.pdf");
        row.put("URLS3", "s3://bucket/file.pdf");
        row.put("CONTENIDO", new ByteArrayInputStream("PDF".getBytes()));

        writer.mergeWithBlob("TARCHIVO", "PK_TARCHIVO", row, List.of("CONTENIDO"));

        // Pin the rendered SQL exactly so future refactors cannot regress
        // (the previous version duplicated the PK in INSERT, raising
        // ORA-00957 — see the round-1 review).
        String expectedSql =
                "MERGE INTO TARCHIVO t USING (SELECT :PK_TARCHIVO AS PK_TARCHIVO, "
                        + ":URL AS URL, :URLS3 AS URLS3, :CONTENIDO AS CONTENIDO FROM DUAL) src "
                        + "ON (t.PK_TARCHIVO = src.PK_TARCHIVO) "
                        + "WHEN MATCHED THEN UPDATE SET t.URL = src.URL, t.URLS3 = src.URLS3 "
                        + "WHEN NOT MATCHED THEN INSERT (URL, URLS3) VALUES (src.URL, src.URLS3)";
        verify(jdbc).update(eq(expectedSql), any(MapSqlParameterSource.class));

        // Confirm CONTENIDO was bound as an InputStream (Spring routes this
        // through setBinaryStream against the BLOB column).
        ArgumentCaptor<MapSqlParameterSource> captor = ArgumentCaptor.forClass(MapSqlParameterSource.class);
        verify(jdbc).update(eq(expectedSql), captor.capture());
        MapSqlParameterSource params = captor.getValue();
        assertThat(params.getValue("CONTENIDO")).isInstanceOf(InputStream.class);
        assertThat(params.getValue("PK_TARCHIVO")).isEqualTo(1L);
        assertThat(params.getValue("URL")).isEqualTo("/file.pdf");
        assertThat(params.getValue("URLS3")).isEqualTo("s3://bucket/file.pdf");
    }
}