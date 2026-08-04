package com.example.cdc.worker;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.worker.pipeline.AuditRecord;
import com.example.cdc.worker.pipeline.ClickHouseAuditStage;
import com.example.cdc.worker.pipeline.JsonTypedRowBuilder;
import com.example.cdc.worker.pipeline.OracleReverseStage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class PipelineExecutor {

    private static final Logger log = LoggerFactory.getLogger(PipelineExecutor.class);

    private final ClickHouseAuditStage clickHouseStage;
    private final OracleReverseStage oracleStage;
    private final WorkerMetrics workerMetrics;
    private final JsonTypedRowBuilder typedRowBuilder;
    private final int maxAttempts;
    private final long initialBackoffMs;
    private final long maxBackoffMs;
    private final boolean clickhouseEnabled;
    private final boolean oracleEnabled;

    public PipelineExecutor(ClickHouseAuditStage clickHouseStage,
                            OracleReverseStage oracleStage,
                            WorkerMetrics workerMetrics,
                            ColumnTypeRegistry registry,
                            @Value("${cdc.retry.max-attempts}") int maxAttempts,
                            @Value("${cdc.retry.initial-backoff-ms}") long initialBackoffMs,
                            @Value("${cdc.retry.max-backoff-ms}") long maxBackoffMs,
                            @Value("${cdc.destinations.clickhouse.enabled:true}") boolean clickhouseEnabled,
                            @Value("${cdc.destinations.oracle.enabled:true}") boolean oracleEnabled) {
        this.clickHouseStage = clickHouseStage;
        this.oracleStage = oracleStage;
        this.workerMetrics = workerMetrics;
        this.typedRowBuilder = new JsonTypedRowBuilder(registry);
        this.maxAttempts = maxAttempts;
        this.initialBackoffMs = initialBackoffMs;
        this.maxBackoffMs = maxBackoffMs;
        this.clickhouseEnabled = clickhouseEnabled;
        this.oracleEnabled = oracleEnabled;
        log.info("cdc-worker destinations: clickhouse={} oracle={}",
                clickhouseEnabled ? "enabled" : "DISABLED",
                oracleEnabled ? "enabled" : "DISABLED");
    }

    public void execute(CdcEvent event, long lsn, long xid, int seq) throws Exception {
        long startTs = System.currentTimeMillis();
        long latenciaMs = startTs - (event.tsMs() != null ? event.tsMs() : startTs);

        // 1. ClickHouse audit (sin retry — falla rápido).
        // Skip completo cuando cdc.destinations.clickhouse.enabled=false: no se
        // construye AuditRecord, no se mide latencia, no se contabiliza timer.
        if (!clickhouseEnabled) {
            log.debug("clickhouse stage skipped (disabled) tabla={} lsn={}",
                    event.tableName(), lsn);
            // Si Oracle también está deshabilitado, no hay nada que hacer: el
            // evento se considera consumido y AmqpConsumer lo ack-ea.
            if (!oracleEnabled) {
                log.debug("oracle stage skipped (disabled) tabla={} lsn={} — nothing to do",
                        event.tableName(), lsn);
                return;
            }
        } else {
            AuditRecord record = AuditRecord.fromEvent(event, seq, lsn, xid,
                    null, "OK", latenciaMs, typedRowBuilder);
            long chStart = System.nanoTime();
            try {
                clickHouseStage.execute(record);
            } finally {
                long chMillis = (System.nanoTime() - chStart) / 1_000_000;
                workerMetrics.recordClickHouseInsert(chMillis);
            }
        }

        // 2. Oracle reverse-sync (con retry). Skip completo cuando
        // cdc.destinations.oracle.enabled=false: no se invoca oracleStage, no
        // se gastan reintentos, no se cae al DLQ por esta vía.
        if (!oracleEnabled) {
            log.debug("oracle stage skipped (disabled) tabla={} lsn={}",
                    event.tableName(), lsn);
            return;
        }

        String tablaOrigen = null;
        try {
            tablaOrigen = executeWithRetry(event);
        } catch (Exception e) {
            // Solo intentamos registrar el DLQ en ClickHouse si ClickHouse
            // sigue habilitado; si está deshabilitado, vamos directo al DLQ
            // del broker para que el operador vea el fallo en la cola.
            if (clickhouseEnabled) {
                AuditRecord dlqRecord = AuditRecord.fromEvent(event, seq, lsn, xid,
                        tablaOrigen, "DLQ", latenciaMs, typedRowBuilder);
                long chDlqStart = System.nanoTime();
                try {
                    clickHouseStage.execute(dlqRecord);
                } finally {
                    long chDlqMillis = (System.nanoTime() - chDlqStart) / 1_000_000;
                    workerMetrics.recordClickHouseInsert(chDlqMillis);
                }
            }
            throw e;
        }
    }

    private String executeWithRetry(CdcEvent event) throws Exception {
        long backoff = initialBackoffMs;
        Exception lastException = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                return oracleStage.execute(event);
            } catch (InterruptedException ie) {
                // Preserve interrupt status so the JVM/thread-pool can honour shutdown.
                Thread.currentThread().interrupt();
                throw ie;
            } catch (Exception e) {
                lastException = e;
                log.warn("Oracle stage intento {}/{} falló: {}", attempt, maxAttempts, e.getMessage());
                if (attempt < maxAttempts) {
                    Thread.sleep(backoff);
                    backoff = Math.min(backoff * 2, maxBackoffMs);
                }
            }
        }
        throw new RuntimeException("Oracle stage agotó reintentos", lastException);
    }
}