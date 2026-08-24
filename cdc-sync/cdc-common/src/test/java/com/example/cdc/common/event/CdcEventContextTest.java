package com.example.cdc.common.event;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifies that {@link CdcEvent} round-trips the contexto fields produced by
 * the academico_test audit_ctx trigger (app_user, db_user, sesion_id, familia,
 * request_id, etiqueta, contexto), plus the Debezium logical-message block.
 */
class CdcEventContextTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void envelope_lifts_context_into_record_and_message_into_payload() throws Exception {
        String json = """
            {
              "payload": {
                "op": "m",
                "source": {"schema": "public", "table": null, "txId": 555},
                "ts_ms": 1712345678000,
                "message": {"prefix": "audit_ctx", "data": "{\\"app_user\\":\\"alice\\"}"}
              },
              "routing_key": "audit_ctx",
              "context": {
                "app_user": "alice",
                "app_user_id": "42",
                "db_user": "postgres",
                "sesion_id": "S-42",
                "familia": "ADMIN",
                "request_id": "req-99",
                "etiqueta": "t",
                "contexto": {"key": "value"}
              }
            }
            """;

        CdcEvent event = mapper.readValue(json, CdcEvent.class);

        assertThat(event.op()).isEqualTo(Operation.MESSAGE);
        assertThat(event.routingKey()).isEqualTo("audit_ctx");
        assertThat(event.message()).isNotNull();
        assertThat(event.message().prefix()).isEqualTo("audit_ctx");
        assertThat(event.message().data()).contains("alice");
        assertThat(event.context()).isNotNull();
        assertThat(event.context().appUser()).isEqualTo("alice");
        assertThat(event.context().appUserId()).isEqualTo("42");
        assertThat(event.context().dbUser()).isEqualTo("postgres");
        assertThat(event.context().sesionId()).isEqualTo("S-42");
        assertThat(event.context().familia()).isEqualTo("ADMIN");
        assertThat(event.context().requestId()).isEqualTo("req-99");
        assertThat(event.context().etiqueta()).isEqualTo("t");
        assertThat(event.context().contexto()).containsEntry("key", "value");
    }

    @Test
    void row_event_can_carry_attached_context() throws Exception {
        String json = """
            {
              "payload": {
                "op": "c",
                "after": {"id": 1},
                "source": {"schema": "public", "table": "clientes", "lsn": 1, "txId": 1, "snapshot": "false"}
              },
              "routing_key": "public.clientes",
              "context": {
                "app_user": "alice",
                "db_user": "postgres",
                "sesion_id": "S-42",
                "familia": "ADMIN",
                "request_id": "req-99",
                "etiqueta": "t"
              }
            }
            """;

        CdcEvent event = mapper.readValue(json, CdcEvent.class);

        assertThat(event.op()).isEqualTo(Operation.INSERT);
        assertThat(event.message()).isNull();
        assertThat(event.context()).isNotNull();
        assertThat(event.context().familia()).isEqualTo("ADMIN");
    }
}
