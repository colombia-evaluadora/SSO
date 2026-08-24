package com.example.cdc.worker;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.audit.Slot;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.event.CdcEvent.Source;
import com.example.cdc.worker.pipeline.AuditRecord;
import com.example.cdc.worker.pipeline.ClickHouseAuditStage;
import com.example.cdc.worker.pipeline.ClickHouseSessionMirrorStage;
import com.example.cdc.worker.pipeline.OracleReverseStage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PipelineExecutorTest {

    private ClickHouseAuditStage clickHouseStage;
    private ClickHouseSessionMirrorStage sessionMirrorStage;
    private OracleReverseStage oracleStage;
    private WorkerMetrics workerMetrics;
    private ColumnTypeRegistry registry;

    private static CdcEvent sampleEvent() {
        Source src = new Source("academico", "academico_test", "tdepartamento", 1L, 100L, "false");
        return new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("codigo", "TEST", "nombre", "DPTO"),
                src,
                System.currentTimeMillis(),
                "academico_test.tdepartamento",
                null,
                null);
    }

    /** V-audit-ctx-4 (sesiones reales): mismo evento pero con tabla=tsesion_web. */
    private static CdcEvent sampleTsesionWebEvent() {
        Source src = new Source("academico", "academico_test", "tsesion_web", 1L, 100L, "false");
        return new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("family_id", "fam-uuid-abc", "pk_tsesion_web", 1L, "fk_tusuario", 42L),
                src,
                System.currentTimeMillis(),
                "academico_test.tsesion_web",
                null,
                null);
    }

    @BeforeEach
    void setUp() {
        clickHouseStage = mock(ClickHouseAuditStage.class);
        sessionMirrorStage = mock(ClickHouseSessionMirrorStage.class);
        oracleStage = mock(OracleReverseStage.class);
        workerMetrics = mock(WorkerMetrics.class);
        registry = mock(ColumnTypeRegistry.class);
        // JsonTypedRowBuilder calls registry.slotFor(tabla, columna) for each
        // column in fila_new/fila_old. Returning TEXTO for any lookup keeps
        // AuditRecord.fromEvent from NPE-ing on the mock.
        when(registry.slotFor(anyString(), anyString())).thenReturn(Slot.TEXTO);
    }

    private PipelineExecutor build(boolean clickhouseEnabled, boolean oracleEnabled) throws Exception {
        return new PipelineExecutor(
                clickHouseStage, sessionMirrorStage, oracleStage, workerMetrics, registry,
                5, 0L, 0L,
                clickhouseEnabled, oracleEnabled);
    }

    @Test
    void both_destinations_enabled_calls_both_stages() throws Exception {
        PipelineExecutor executor = build(true, true);
        when(oracleStage.execute(any())).thenReturn("tdepartamento");

        executor.execute(sampleEvent(), 100L, 1L, 0);

        verify(clickHouseStage, times(1)).execute(any(AuditRecord.class));
        verify(oracleStage, times(1)).execute(any(CdcEvent.class));
    }

    @Test
    void oracle_disabled_skips_oracle_stage_and_does_not_retry() throws Exception {
        PipelineExecutor executor = build(true, false);
        // Even if oracle stage would throw, it should never be called.
        when(oracleStage.execute(any())).thenThrow(new RuntimeException("would fail"));

        executor.execute(sampleEvent(), 100L, 1L, 0);

        verify(clickHouseStage, times(1)).execute(any(AuditRecord.class));
        verify(oracleStage, never()).execute(any(CdcEvent.class));
    }

    @Test
    void clickhouse_disabled_skips_audit_insert_but_still_runs_oracle() throws Exception {
        PipelineExecutor executor = build(false, true);
        when(oracleStage.execute(any())).thenReturn("tdepartamento");

        executor.execute(sampleEvent(), 100L, 1L, 0);

        verify(clickHouseStage, never()).execute(any(AuditRecord.class));
        verify(oracleStage, times(1)).execute(any(CdcEvent.class));
    }

    @Test
    void both_destinations_disabled_runs_neither_stage_and_does_not_throw() throws Exception {
        PipelineExecutor executor = build(false, false);

        // Neither stage should be invoked, and the call should return cleanly.
        executor.execute(sampleEvent(), 100L, 1L, 0);

        verify(clickHouseStage, never()).execute(any(AuditRecord.class));
        verify(oracleStage, never()).execute(any(CdcEvent.class));
    }

    @Test
    void oracle_failure_with_clickhouse_enabled_writes_dlq_record() throws Exception {
        PipelineExecutor executor = build(true, true);
        when(oracleStage.execute(any())).thenThrow(new RuntimeException("ORA-00904"));

        assertThatThrownBy(() -> executor.execute(sampleEvent(), 100L, 1L, 0))
                .isInstanceOf(RuntimeException.class)
                .hasMessageContaining("Oracle stage agotó reintentos");

        // First call: the "OK" record. Second call: the "DLQ" record after retries.
        verify(clickHouseStage, times(2)).execute(any(AuditRecord.class));
    }

    @Test
    void oracle_failure_with_clickhouse_disabled_skips_dlq_record() throws Exception {
        PipelineExecutor executor = build(false, true);
        when(oracleStage.execute(any())).thenThrow(new RuntimeException("ORA-00904"));

        assertThatThrownBy(() -> executor.execute(sampleEvent(), 100L, 1L, 0))
                .isInstanceOf(RuntimeException.class);

        // ClickHouse disabled → no audit insert, no DLQ record.
        verify(clickHouseStage, never()).execute(any(AuditRecord.class));
    }

    /* ====================== V-audit-ctx-4 (sesiones reales) ====================== */

    @Test
    void tsesion_web_event_runs_session_mirror_in_addition_to_audit_log() throws Exception {
        // V-audit-ctx-4: un INSERT/UPDATE/DELETE sobre tsesion_web
        // dispara TANTO el audit_log estándar COMO el mirror a
        // auditoria.tsesion_web. Oracle no aplica (tsesion_web es
        // solo-Postgres, no replica a Oracle).
        PipelineExecutor executor = build(true, false);

        executor.execute(sampleTsesionWebEvent(), 100L, 1L, 0);

        verify(clickHouseStage, times(1)).execute(any(AuditRecord.class));
        verify(sessionMirrorStage, times(1)).execute(any(CdcEvent.class), anyLong());
        verify(oracleStage, never()).execute(any(CdcEvent.class));
    }

    @Test
    void non_tsesion_web_event_does_not_invoke_session_mirror() throws Exception {
        // Sanity: una tabla cualquiera NO dispara el mirror, sólo
        // audit_log (y Oracle si aplica).
        PipelineExecutor executor = build(true, true);
        when(oracleStage.execute(any())).thenReturn("tdepartamento");

        executor.execute(sampleEvent(), 100L, 1L, 0);

        verify(clickHouseStage, times(1)).execute(any(AuditRecord.class));
        verify(sessionMirrorStage, never()).execute(any(CdcEvent.class), anyLong());
        verify(oracleStage, times(1)).execute(any(CdcEvent.class));
    }

    @Test
    void session_mirror_failure_does_not_fail_the_event() throws Exception {
        // El mirror es best-effort -- si falla, el evento sigue su
        // curso (audit_log YA quedó escrito, Oracle se ejecuta igual).
        // Un fallo del mirror NO debe terminar en DLQ.
        PipelineExecutor executor = build(true, true);
        when(oracleStage.execute(any())).thenReturn("tsesion_web");
        org.mockito.Mockito.doThrow(new RuntimeException("ClickHouse mirror send failed"))
                .when(sessionMirrorStage).execute(any(CdcEvent.class), anyLong());

        executor.execute(sampleTsesionWebEvent(), 100L, 1L, 0);

        verify(clickHouseStage, times(1)).execute(any(AuditRecord.class));
        verify(sessionMirrorStage, times(1)).execute(any(CdcEvent.class), anyLong());
        verify(oracleStage, times(1)).execute(any(CdcEvent.class));
    }
}