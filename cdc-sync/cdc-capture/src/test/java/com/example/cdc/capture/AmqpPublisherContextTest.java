package com.example.cdc.capture;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.example.cdc.common.event.CdcEvent;
import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.amqp.core.MessagePostProcessor;
import org.springframework.amqp.rabbit.core.RabbitTemplate;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

class AmqpPublisherContextTest {

    private final ObjectMapper mapper = new ObjectMapper();
    private RabbitTemplate template;
    private CaptureMetrics metrics;
    private AuditContextCache cache;
    private AmqpPublisher publisher;

    @BeforeEach
    void setUp() {
        template = mock(RabbitTemplate.class);
        metrics = mock(CaptureMetrics.class);
        cache = new AuditContextCache();
        publisher = new AmqpPublisher(template, metrics, "cdc.events", cache);
    }

    @Test
    void logical_message_event_is_not_published_and_is_cached() throws Exception {
        String auditJson = mapper.writeValueAsString(Map.of(
                "app_user", "alice",
                "db_user", "postgres",
                "sesion_id", "S-42",
                "familia", "ADMIN",
                "request_id", "req-1",
                "etiqueta", "etiqueta-1",
                "contexto", Map.of("sesion_id", "S-42", "familia", "ADMIN")
        ));
        Map<String, Object> payload = Map.of(
                "op", "m",
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 555, "lsn", 100, "snapshot", "false"),
                "message", Map.of("prefix", "audit_ctx", "content", b64(auditJson))
        );

        handleSingle(payload);

        // MESSAGE events are correlation artifacts — they MUST NOT be published
        // as row events. The cache holds 1 entry until a matching row event calls
        // take(); we don't manually evict here.
        verify(template, never()).convertAndSend(any(), any(), any(Object.class), any(MessagePostProcessor.class));
        assertThat(cache.size()).isEqualTo(1);
        // take() removes the entry on read.
        CdcEvent.Context cached = publisher.getContextCache().take(555L);
        assertThat(cached).isNotNull();
        assertThat(cached.appUser()).isEqualTo("alice");
        assertThat(cached.familia()).isEqualTo("ADMIN");
    }

    @Test
    void row_event_after_logical_message_picks_up_cached_context() throws Exception {
        String auditJson = mapper.writeValueAsString(Map.of(
                "app_user", "alice",
                "app_user_id", "42",
                "db_user", "postgres",
                "sesion_id", "S-42",
                "familia", "ADMIN",
                "request_id", "req-7",
                "etiqueta", "t",
                "contexto", Map.of("k", "v")
        ));
        // First: the audit_ctx logical message in xid=555.
        handleSingle(Map.of(
                "op", "m",
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 555, "lsn", 100, "snapshot", "false"),
                "message", Map.of("prefix", "audit_ctx", "content", b64(auditJson))
        ));

        // Second: a real INSERT in the same transaction.
        handleSingle(Map.of(
                "op", "c",
                "after", Map.of("pk_tusuario", 99, "nombre", "Alice"),
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 555, "lsn", 105, "snapshot", "false")
        ));

        ArgumentCaptor<Object> bodyCaptor = ArgumentCaptor.forClass(Object.class);
        verify(template).convertAndSend(eq("cdc.events"), eq("public.tusuario"),
                bodyCaptor.capture(), any(MessagePostProcessor.class));

        String json = mapper.writeValueAsString(bodyCaptor.getValue());
        Map<String, Object> envelope = mapper.readValue(json, new TypeReference<Map<String, Object>>() {});

        assertThat(envelope).containsKey("context");
        Map<String, Object> ctx = (Map<String, Object>) envelope.get("context");
        assertThat(ctx).containsEntry("app_user", "alice");
        assertThat(ctx).containsEntry("app_user_id", "42");
        assertThat(ctx).containsEntry("familia", "ADMIN");
        assertThat(ctx).containsEntry("request_id", "req-7");
    }

    @Test
    void row_event_without_prior_audit_ctx_omits_context() throws Exception {
        // Row event in txid=999 — no preceding MESSAGE.
        handleSingle(Map.of(
                "op", "c",
                "after", Map.of("pk_tusuario", 1),
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 999, "lsn", 1, "snapshot", "false")
        ));

        ArgumentCaptor<Object> bodyCaptor = ArgumentCaptor.forClass(Object.class);
        verify(template).convertAndSend(eq("cdc.events"), eq("public.tusuario"),
                bodyCaptor.capture(), any(MessagePostProcessor.class));

        String json = mapper.writeValueAsString(bodyCaptor.getValue());
        Map<String, Object> envelope = mapper.readValue(json, new TypeReference<Map<String, Object>>() {});

        assertThat(envelope).doesNotContainKey("context");
    }

    @Test
    void unknown_logical_message_prefix_is_silently_dropped() throws Exception {
        Map<String, Object> payload = Map.of(
                "op", "m",
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 100, "lsn", 1, "snapshot", "false"),
                "message", Map.of("prefix", "other_audit", "content", b64("{}"))
        );

        handleSingle(payload);

        verify(template, never()).convertAndSend(any(), any(), any(Object.class), any(MessagePostProcessor.class));
    }

    @Test
    void snapshot_event_is_not_published_and_is_counted_as_skipped() throws Exception {
        // Debezium emits a snapshot row as op="r" with source.snapshot="true". These are
        // bootstrap artifacts (SELECT * at engine start) and MUST NOT be published: they
        // would otherwise land in auditoria.audit_log as operacion='r' rows AND trigger
        // MERGEs in Oracle via ColumnRenamer's snapshot branch.
        // Map.of rechaza valores null con NPE, y Debezium emite
        // "before": null en las filas de snapshot. Se construye con
        // HashMap para poder incluir esa clave explícitamente: si se
        // omitiera, el payload dejaría de parecerse al real.
        Map<String, Object> payload = new HashMap<>();
        payload.put("op", "r");
        payload.put("before", null);
        payload.put("after", Map.of("pk_tusuario", 1, "nombre", "Alice"));
        payload.put("source", Map.of("schema", "public", "table", "tusuario",
                "txId", 0, "lsn", 1, "snapshot", "true"));

        handleSingle(payload);

        verify(template, never()).convertAndSend(any(), any(), any(Object.class), any(MessagePostProcessor.class));
        verify(metrics).incrementSnapshotSkipped("tusuario");
    }

    /**
     * Matches the real shape Debezium's {@code LogicalDecodingMessageMonitor}
     * produces for a logical message's {@code content} field under the default
     * {@code binary.handling.mode} — see {@link AmqpPublisher#parseAuditContext}.
     * Fixtures using plain text under {@code data} (the old, wrong key) let this
     * suite pass while the real pipeline silently dropped every audit_ctx message.
     */
    private static String b64(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    private void handleSingle(Map<String, Object> payload) throws Exception {
        String json = mapper.writeValueAsString(payload);
        ChangeEvent<String, String> event = new ChangeEvent<String, String>() {
            public String key() { return null; }
            public String value() { return json; }
            public String destination() { return null; }
            public Integer partition() { return null; }
        };
        @SuppressWarnings("unchecked")
        DebeziumEngine.RecordCommitter<ChangeEvent<String, String>> committer =
            (DebeziumEngine.RecordCommitter<ChangeEvent<String, String>>)
                (DebeziumEngine.RecordCommitter<?>) mock(DebeziumEngine.RecordCommitter.class);
        publisher.handleBatch(List.of(event), committer);
    }
}
