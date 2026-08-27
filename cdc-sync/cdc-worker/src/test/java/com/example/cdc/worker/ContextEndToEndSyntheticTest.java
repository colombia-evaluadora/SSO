package com.example.cdc.worker;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.audit.Slot;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.worker.pipeline.AuditRecord;
import com.example.cdc.worker.pipeline.JsonTypedRowBuilder;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Synthetic end-to-end check that walks the worker-side code path the
 * production pipeline walks, just without spinning up Testcontainers (RabbitMQ
 * + ClickHouse + Oracle). It validates the contract between the
 * capture-side envelope (proved separately by
 * {@code cdc-capture/AmqpPublisherContextTest}) and the
 * {@link AuditRecord} that ends up being inserted into
 * {@code auditoria.audit_log}.
 *
 * <p>The synthetic envelope mirrors exactly what {@code AmqpPublisher} emits
 * when correlated with an {@code audit_ctx} logical message: a JSON envelope
 * with {@code payload}, {@code routing_key} and {@code context} at the root.
 * The worker parses it via {@link CdcEvent#fromJson} (the same code path
 * invoked by {@code AmqpConsumer}) and then builds the {@link AuditRecord}
 * via {@code AuditRecord.fromEvent} (the same code path invoked by
 * {@code PipelineExecutor}).
 *
 * <p>If both unit tests pass, the seven audit_ctx fields are guaranteed to
 * land in the seven corresponding columns of ClickHouse's
 * {@code auditoria.audit_log} table — because {@code ClickHouseAuditStage.toRow}
 * is a 1:1 mapper from {@code AuditRecord} fields to column names.
 */
class ContextEndToEndSyntheticTest {

    private final ObjectMapper mapper = new ObjectMapper();

    private ColumnTypeRegistry registry;
    private JsonTypedRowBuilder typedRowBuilder;

    @BeforeEach
    void setUp() {
        registry = mock(ColumnTypeRegistry.class);
        when(registry.slotFor(anyString(), anyString())).thenReturn(Slot.TEXTO);
        typedRowBuilder = new JsonTypedRowBuilder(registry);
    }

    @Test
    void eight_audit_ctx_fields_propagate_envelope_to_audit_record() throws Exception {
        // ── 1. Simulated Debezium audit_ctx message body (from the trigger). ──
        Map<String, Object> rawContext = new LinkedHashMap<>();
        rawContext.put("app_user",   "alice.morales");
        rawContext.put("app_user_id", "4242");
        rawContext.put("db_user",    "postgres");
        rawContext.put("sesion_id",  "S-2026-08-03-001");
        rawContext.put("familia",    "ADMIN");
        rawContext.put("request_id", "req-2026-08-03-55ab");
        rawContext.put("etiqueta",   "evaluacion_docente");
        rawContext.put("contexto",   Map.of("rol", "docente", "establecimiento", "E-7"));

        // ── 2. Synthetic envelope AmqpPublisher would emit, in full. ──
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("payload", Map.of(
                "op", "c",
                "after", Map.of(
                        "pk_tusuario", 4242,
                        "tipo_documento", "CC",
                        "identificacion", "123456789",
                        "primer_nombre", "Alice"
                ),
                "source", Map.of(
                        "schema", "academico_test",
                        "table",  "tusuario",
                        "txId",   12345L,
                        "lsn",    9002L,
                        "snapshot", "false"
                ),
                "ts_ms", 1712345678000L
        ));
        envelope.put("routing_key", "academico_test.tusuario");
        envelope.put("context", rawContext);

        String envelopeJson = mapper.writeValueAsString(envelope);

        // ── 3. Worker intake: CdcEvent.fromJson. ──
        CdcEvent event = mapper.readValue(envelopeJson, CdcEvent.class);

        assertThat(event.op()).isEqualTo(Operation.INSERT);
        assertThat(event.routingKey()).isEqualTo("academico_test.tusuario");
        assertThat(event.context())
                .as("CdcEvent.Context must be lifted from envelope.context")
                .isNotNull();

        // ── 4. Worker pipeline: AuditRecord.fromEvent. ──
        AuditRecord record = AuditRecord.fromEvent(
                event, /*seq*/ 0, /*lsn*/ 9002L, /*xid*/ 12345L,
                null, "OK", /*latenciaMs*/ 5L, typedRowBuilder);

        // ── 5. Verify all eight audit_ctx fields reach AuditRecord. ──
        assertThat(record.appUser()).isEqualTo("alice.morales");
        assertThat(record.appUserId()).isEqualTo("4242");
        assertThat(record.dbUser()).isEqualTo("postgres");
        assertThat(record.sesionId()).isEqualTo("S-2026-08-03-001");
        assertThat(record.familia()).isEqualTo("ADMIN");
        assertThat(record.requestId()).isEqualTo("req-2026-08-03-55ab");
        assertThat(record.etiqueta()).isEqualTo("evaluacion_docente");
        assertThat(record.contextoJson())
                .contains("\"rol\":\"docente\"")
                .contains("\"establecimiento\":\"E-7\"");
    }

    @Test
    void envelope_without_context_yields_empty_string_columns() throws Exception {
        // Sanity counterpart: a row event whose envelope has no context block
        // (because the trigger never ran, or correlation expired) must
        // produce empty-string columns — never null — so ClickHouse accepts
        // the INSERT.
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("payload", Map.of(
                "op", "c",
                "after", Map.of("pk_tusuario", 1),
                "source", Map.of(
                        "schema", "academico_test",
                        "table",  "tusuario",
                        "txId",   99999L,
                        "lsn",    1L,
                        "snapshot", "false"
                )
        ));
        envelope.put("routing_key", "academico_test.tusuario");
        // No "context" key — AmqpPublisher only adds it when the cache hit.

        CdcEvent event = mapper.readValue(mapper.writeValueAsString(envelope), CdcEvent.class);
        assertThat(event.context()).isNull();

        AuditRecord record = AuditRecord.fromEvent(
                event, 0, 1L, 99999L, null, "OK", 1L, typedRowBuilder);

        // Empty strings, not null — AuditRecord.fromEvent guarantees this.
        assertThat(record.appUser()).isEqualTo("");
        assertThat(record.appUserId()).isEqualTo("");
        assertThat(record.dbUser()).isEqualTo("");
        assertThat(record.sesionId()).isEqualTo("");
        assertThat(record.familia()).isEqualTo("");
        assertThat(record.requestId()).isEqualTo("");
        assertThat(record.etiqueta()).isEqualTo("");
        assertThat(record.contextoJson()).isEqualTo("");
    }
}
