package com.example.cdc.worker;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.audit.Slot;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.event.CdcEvent.Source;
import com.example.cdc.worker.pipeline.AuditRecord;
import com.example.cdc.worker.pipeline.ClickHouseAuditStage;
import com.example.cdc.worker.pipeline.OracleReverseStage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PipelineExecutorTest {

    private ClickHouseAuditStage clickHouseStage;
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

    @BeforeEach
    void setUp() {
        clickHouseStage = mock(ClickHouseAuditStage.class);
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
                clickHouseStage, oracleStage, workerMetrics, registry,
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
}