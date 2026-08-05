package com.example.cdc.worker.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.snapshot.S3BlobFetcher;
import com.example.cdc.worker.oracle.OracleJdbcWriter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Reverse-sync transformer for the PG {@code tarchivo} table.
 *
 * <p>Bridges the PG "URLS3-only" world to Oracle's {@code CONTENIDO BLOB NOT NULL}
 * expectation: for INSERT and UPDATE events whose {@code urls3} changed, the
 * transformer downloads the blob via the injected {@link S3BlobFetcher}, streams
 * it to Oracle via {@link OracleJdbcWriter#mergeWithBlob(String, String, Map, List)},
 * and derives the Oracle {@code URL} column by stripping the {@code s3://bucket/}
 * prefix. DELETEs delegate to {@link OracleJdbcWriter#delete(String, String, Object)}.
 *
 * <p>Per the spec (section 3.6), failure modes — null URLS3, blob over the size
 * threshold, fetch exceptions — are mapped to WARN + skip so a single bad row
 * does not dead-letter the whole event stream.
 *
 * <p>Lives in {@code cdc-worker} (not {@code cdc-common}) because it depends on
 * {@link OracleJdbcWriter}, which itself depends on Spring's JDBC template and
 * is part of the worker's Oracle write path.
 */
public class TArchivoBlobDropper {

    private static final Logger log = LoggerFactory.getLogger(TArchivoBlobDropper.class);

    private static final String ORACLE_TABLE = "TARCHIVO";
    private static final String PK_COLUMN = "PK_TARCHIVO";
    private static final String BLOB_COLUMN = "CONTENIDO";
    private static final List<String> BLOB_COLUMNS = List.of(BLOB_COLUMN);

    private static final String PG_PK = "pk_tarchivo";
    private static final String PG_URLS3 = "urls3";

    /** Strip the {@code s3://bucket/} prefix to derive the Oracle {@code URL} path. */
    private static final java.util.regex.Pattern S3_SCHEME_BUCKET =
            java.util.regex.Pattern.compile("^s3://[^/]+/");

    private final S3BlobFetcher fetcher;
    private final OracleJdbcWriter writer;
    private final long maxBytes;

    public TArchivoBlobDropper(S3BlobFetcher fetcher, OracleJdbcWriter writer, long maxBytes) {
        this.fetcher = fetcher;
        this.writer = writer;
        this.maxBytes = maxBytes;
    }

    /**
     * Apply the transformer to a single {@link CdcEvent}. Idempotent: events
     * that do not change {@code urls3} are silently skipped so CDC at-least-once
     * delivery does not produce duplicate BLOB fetches.
     */
    public void apply(CdcEvent event) {
        if (event.op() == Operation.DELETE) {
            Object pk = event.before() != null ? event.before().get(PG_PK) : null;
            log.debug("tarchivo delete pk={}", pk);
            writer.delete(ORACLE_TABLE, PK_COLUMN, pk);
            return;
        }

        Map<String, Object> row = event.after();
        if (row == null) {
            log.warn("Skipping tarchivo {}: empty after-row", event.op());
            return;
        }

        String urlS3 = asString(row.get(PG_URLS3));
        if (urlS3 == null || urlS3.isBlank()) {
            log.warn("Skipping tarchivo pk={} due to null/blank urls3", row.get(PG_PK));
            return;
        }

        // Idempotency: re-deliveries of an UPDATE where urls3 did not change
        // are silently skipped so we don't re-fetch and re-stream the same blob.
        if (event.op() == Operation.UPDATE) {
            String beforeUrl = event.before() != null ? asString(event.before().get(PG_URLS3)) : null;
            if (urlS3.equals(beforeUrl)) {
                log.debug("tarchivo pk={} urls3 unchanged; skipping", row.get(PG_PK));
                return;
            }
        }

        try (InputStream blob = fetcher.fetchBlob(urlS3)) {
            byte[] content = blob.readAllBytes();
            if (content.length > maxBytes) {
                log.warn("Skipping tarchivo pk={} BLOB too large: {} bytes (max {})",
                        row.get(PG_PK), content.length, maxBytes);
                return;
            }

            Map<String, Object> oracleRow = new LinkedHashMap<>(row);
            oracleRow.put(BLOB_COLUMN, new ByteArrayInputStream(content));
            oracleRow.put("URL", S3_SCHEME_BUCKET.matcher(urlS3).replaceFirst(""));
            oracleRow.put("URLS3", urlS3);

            writer.mergeWithBlob(ORACLE_TABLE, PK_COLUMN, oracleRow, BLOB_COLUMNS);
        } catch (S3BlobFetcher.S3FetchException | IOException e) {
            log.warn("Skipping tarchivo pk={} due to fetch error: {}",
                    row.get(PG_PK), e.getMessage());
        }
    }

    private static String asString(Object o) {
        if (o == null) return null;
        return o.toString();
    }
}