package com.example.cdc.worker.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.snapshot.S3BlobFetcher;
import com.example.cdc.worker.oracle.OracleJdbcWriter;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.io.ByteArrayInputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;

class TArchivoBlobDropperTest {

    private static final String TABLE = "tarchivo";

    private S3BlobFetcher fetcher;
    private OracleJdbcWriter writer;
    private TArchivoBlobDropper tx;

    @BeforeEach
    void setUp() {
        fetcher = Mockito.mock(S3BlobFetcher.class);
        writer = Mockito.mock(OracleJdbcWriter.class);
        // 100 MB cap, matches cdc.s3.max-bytes default in Phase 1
        tx = new TArchivoBlobDropper(fetcher, writer, 100L * 1024 * 1024);
    }

    @Test
    void fetchOkTriggersMergeWithBlob() throws Exception {
        Mockito.when(fetcher.fetchBlob("s3://bucket/file.pdf"))
                .thenReturn(new ByteArrayInputStream("PDF".getBytes()));
        CdcEvent ev = insertEvent(Map.of("pk_tarchivo", 1, "urls3", "s3://bucket/file.pdf"));
        tx.apply(ev);
        Mockito.verify(writer).mergeWithBlob(
                eq("TARCHIVO"), eq("PK_TARCHIVO"), anyMap(), eq(List.of("CONTENIDO")));
    }

    @Test
    void fetch4xxSkipsWithWarn() throws Exception {
        Mockito.when(fetcher.fetchBlob(Mockito.anyString()))
                .thenThrow(new S3BlobFetcher.S3FetchException("HTTP 404"));
        CdcEvent ev = insertEvent(Map.of("pk_tarchivo", 2, "urls3", "s3://bucket/missing.pdf"));
        tx.apply(ev);
        Mockito.verify(writer, Mockito.never())
                .mergeWithBlob(anyString(), anyString(), anyMap(), anyList());
    }

    @Test
    void fetch5xxSkips() throws Exception {
        Mockito.when(fetcher.fetchBlob(Mockito.anyString()))
                .thenThrow(new S3BlobFetcher.S3FetchException("HTTP 503"));
        CdcEvent ev = insertEvent(Map.of("pk_tarchivo", 3, "urls3", "s3://bucket/x"));
        tx.apply(ev);
        Mockito.verify(writer, Mockito.never())
                .mergeWithBlob(anyString(), anyString(), anyMap(), anyList());
    }

    @Test
    void fetchTimeoutSkips() throws Exception {
        Mockito.when(fetcher.fetchBlob(Mockito.anyString()))
                .thenThrow(new S3BlobFetcher.S3FetchException("timeout"));
        CdcEvent ev = insertEvent(Map.of("pk_tarchivo", 4, "urls3", "s3://bucket/x"));
        tx.apply(ev);
        Mockito.verify(writer, Mockito.never())
                .mergeWithBlob(anyString(), anyString(), anyMap(), anyList());
    }

    @Test
    void nullUrls3Skips() throws Exception {
        // Map.of does not allow null values, so build a HashMap explicitly.
        Map<String, Object> after = new HashMap<>();
        after.put("pk_tarchivo", 5);
        after.put("urls3", null);
        CdcEvent ev = insertEvent(after);
        tx.apply(ev);
        Mockito.verify(fetcher, Mockito.never()).fetchBlob(anyString());
        Mockito.verify(writer, Mockito.never())
                .mergeWithBlob(anyString(), anyString(), anyMap(), anyList());
    }

    @Test
    void deleteTriggersWriterDelete() {
        CdcEvent ev = deleteEvent(Map.of("pk_tarchivo", 6));
        tx.apply(ev);
        Mockito.verify(writer).delete("TARCHIVO", "PK_TARCHIVO", 6);
    }

    /** Builds an INSERT {@link CdcEvent} mirroring {@code CdcEventFixture.createInsert}. */
    private static CdcEvent insertEvent(Map<String, Object> after) {
        CdcEvent.Source source = new CdcEvent.Source(
                "postgres", "public", TABLE, 1L, 100L, "false");
        return new CdcEvent(Operation.INSERT, null, after, source,
                1_700_000_000_000L, "public." + TABLE, null, null);
    }

    /** Builds a DELETE {@link CdcEvent} mirroring {@code CdcEventFixture.createDelete}. */
    private static CdcEvent deleteEvent(Map<String, Object> before) {
        CdcEvent.Source source = new CdcEvent.Source(
                "postgres", "public", TABLE, 1L, 100L, "false");
        return new CdcEvent(Operation.DELETE, before, null, source,
                1_700_000_000_000L, "public." + TABLE, null, null);
    }
}