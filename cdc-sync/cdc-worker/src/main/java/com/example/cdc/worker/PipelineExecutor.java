package com.example.cdc.worker;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.worker.pipeline.AuditRecord;
import com.example.cdc.worker.pipeline.ClickHouseAuditStage;
import com.example.cdc.worker.pipeline.ClickHouseSessionMirrorStage;
import com.example.cdc.worker.pipeline.JsonTypedRowBuilder;
import com.example.cdc.worker.pipeline.OracleReverseStage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

@Component
public class PipelineExecutor {

    private static final Logger log = LoggerFactory.getLogger(PipelineExecutor.class);

    /**
     * Tabla cuyo cambio se replica a un mirror en ClickHouse además
     * del audit_log estándar. El match se hace contra el nombre
     * CORTO que devuelve {@link CdcEvent#tableName()} ({@code
     * source.table()} en la envelope Debezium), sin prefijo de
     * schema. La suposición de un solo schema académico es segura
     * hoy; si en el futuro tsesion_web se replica en otro schema,
     * comparar también {@code event.schemaName()}.
     */
    private static final String TSESION_WEB_TABLE = "tsesion_web";

    private final ClickHouseAuditStage clickHouseStage;
    private final ClickHouseSessionMirrorStage sessionMirrorStage;
    private final OracleReverseStage oracleStage;
    private final WorkerMetrics workerMetrics;
    private final JsonTypedRowBuilder typedRowBuilder;
    private final int maxAttempts;
    private final long initialBackoffMs;
    private final long maxBackoffMs;
    private final boolean clickhouseEnabled;
    private final boolean oracleEnabled;

    public PipelineExecutor(ClickHouseAuditStage clickHouseStage,
                            ClickHouseSessionMirrorStage sessionMirrorStage,
                            OracleReverseStage oracleStage,
                            WorkerMetrics workerMetrics,
                            ColumnTypeRegistry registry,
                            @Value("${cdc.retry.max-attempts}") int maxAttempts,
                            @Value("${cdc.retry.initial-backoff-ms}") long initialBackoffMs,
                            @Value("${cdc.retry.max-backoff-ms}") long maxBackoffMs,
                            @Value("${cdc.destinations.clickhouse.enabled:true}") boolean clickhouseEnabled,
                            @Value("${cdc.destinations.oracle.enabled:true}") boolean oracleEnabled) {
        this.clickHouseStage = clickHouseStage;
        this.sessionMirrorStage = sessionMirrorStage;
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

    /** Un evento del lote, con los datos de su envelope. */
    public record Evento(CdcEvent event, long lsn, long xid, int seq) {
    }

    public void execute(CdcEvent event, long lsn, long xid, int seq) throws Exception {
        Exception fallo = executeBatch(List.of(new Evento(event, lsn, xid, seq))).get(0);
        if (fallo != null) {
            throw fallo;
        }
    }

    /**
     * Procesa un lote en orden y devuelve, por posicion, null si el evento
     * quedo aplicado o la excepcion que lo manda a la DLQ.
     *
     * <p>Mismo orden que el procesamiento de a uno: primero ClickHouse y
     * despues Oracle. Si el INSERT de audit_log falla, ningun evento del lote
     * llega a Oracle y todos van a la DLQ, asi reprocesarlos no aplica dos
     * veces un cambio en Oracle. audit_log y el mirror de tsesion_web van en
     * un INSERT por lote (antes uno por evento: una parte de ClickHouse por
     * fila).
     */
    public List<Exception> executeBatch(List<Evento> eventos) {
        List<Exception> resultado = new ArrayList<>(Collections.nCopies(eventos.size(), (Exception) null));
        if (eventos.isEmpty()) {
            return resultado;
        }
        long[] latencias = new long[eventos.size()];
        long ahora = System.currentTimeMillis();
        for (int i = 0; i < eventos.size(); i++) {
            Long ts = eventos.get(i).event().tsMs();
            latencias[i] = ahora - (ts != null ? ts : ahora);
        }

        // 1. ClickHouse audit (sin retry — falla rapido). Deshabilitado: no se
        // construye AuditRecord ni se contabiliza timer.
        if (clickhouseEnabled) {
            List<AuditRecord> records = new ArrayList<>(eventos.size());
            for (int i = 0; i < eventos.size(); i++) {
                Evento e = eventos.get(i);
                records.add(AuditRecord.fromEvent(e.event(), e.seq(), e.lsn(), e.xid(),
                        null, "OK", latencias[i], typedRowBuilder));
            }
            long chStart = System.nanoTime();
            try {
                clickHouseStage.executeBatch(records);
            } catch (Exception chEx) {
                Collections.fill(resultado, chEx);
                return resultado;
            } finally {
                workerMetrics.recordClickHouseInsert((System.nanoTime() - chStart) / 1_000_000);
            }
            espejarSesiones(eventos);
        } else {
            log.debug("clickhouse stage skipped (disabled) eventos={}", eventos.size());
        }

        // 2. Oracle reverse-sync (con retry), evento por evento y en orden.
        if (!oracleEnabled) {
            log.debug("oracle stage skipped (disabled) eventos={}", eventos.size());
            return resultado;
        }
        List<AuditRecord> dlqRecords = new ArrayList<>();
        for (int i = 0; i < eventos.size(); i++) {
            Evento e = eventos.get(i);
            try {
                executeWithRetry(e.event());
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                for (int j = i; j < eventos.size(); j++) {
                    resultado.set(j, ie);
                }
                break;
            } catch (Exception oraEx) {
                resultado.set(i, oraEx);
                // Solo se registra el DLQ en ClickHouse si sigue habilitado; si
                // no, el operador lo ve en la cola del broker.
                if (clickhouseEnabled) {
                    dlqRecords.add(AuditRecord.fromEvent(e.event(), e.seq(), e.lsn(), e.xid(),
                            null, "DLQ", latencias[i], typedRowBuilder));
                }
            }
        }
        if (!dlqRecords.isEmpty()) {
            long chDlqStart = System.nanoTime();
            try {
                clickHouseStage.executeBatch(dlqRecords);
            } catch (Exception dlqEx) {
                log.warn("No se pudo registrar en audit_log el DLQ de {} eventos: {}",
                        dlqRecords.size(), dlqEx.getMessage());
            } finally {
                workerMetrics.recordClickHouseInsert((System.nanoTime() - chDlqStart) / 1_000_000);
            }
        }
        return resultado;
    }

    /**
     * Espejo de tsesion_web: los INSERT/UPDATE del lote van en un solo INSERT,
     * pero un DELETE vacia antes lo pendiente para no alterar el orden. Si
     * falla, la fila de audit_log ya quedo y tsesion_web se reconcilia en el
     * siguiente cambio de esa familia: se registra y no manda a la DLQ.
     */
    private void espejarSesiones(List<Evento> eventos) {
        List<Map<String, Object>> pendientes = new ArrayList<>();
        long inicio = System.nanoTime();
        try {
            for (Evento e : eventos) {
                if (!TSESION_WEB_TABLE.equalsIgnoreCase(e.event().tableName())) {
                    continue;
                }
                if (ClickHouseSessionMirrorStage.isDelete(e.event())) {
                    sessionMirrorStage.insertRows(List.copyOf(pendientes));
                    pendientes.clear();
                    sessionMirrorStage.delete(e.event());
                } else {
                    Map<String, Object> fila = sessionMirrorStage.upsertRow(e.event(), e.lsn());
                    if (fila != null) {
                        pendientes.add(fila);
                    }
                }
            }
            sessionMirrorStage.insertRows(pendientes);
        } catch (Exception mirrorEx) {
            log.warn("SessionMirrorStage falló para tabla={} ({} filas pendientes): {}",
                    TSESION_WEB_TABLE, pendientes.size(), mirrorEx.getMessage());
        } finally {
            workerMetrics.recordClickHouseInsert((System.nanoTime() - inicio) / 1_000_000);
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