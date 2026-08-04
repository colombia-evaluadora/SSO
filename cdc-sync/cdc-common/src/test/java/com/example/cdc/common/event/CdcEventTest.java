package com.example.cdc.common.event;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class CdcEventTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void parses_insert_event() throws Exception {
        String json = """
            {
              "payload": {
                "op": "c",
                "before": null,
                "after": {"id": 1, "nombre": "Alice"},
                "source": {"table": "clientes", "lsn": 12345, "txId": 100, "snapshot": "false"},
                "ts_ms": 1712345678000
              },
              "routing_key": "public.clientes"
            }
            """;

        CdcEvent event = mapper.readValue(json, CdcEvent.class);

        assertThat(event.op()).isEqualTo(Operation.INSERT);
        assertThat(event.after()).containsEntry("nombre", "Alice");
        assertThat(event.source().table()).isEqualTo("clientes");
        assertThat(event.routingKey()).isEqualTo("public.clientes");
    }

    @Test
    void parses_snapshot_event() throws Exception {
        String json = """
            {
              "payload": {
                "op": "r",
                "before": null,
                "after": {"id": 1},
                "source": {"table": "clientes", "lsn": 0, "snapshot": "true"}
              }
            }
            """;

        CdcEvent event = mapper.readValue(json, CdcEvent.class);

        assertThat(event.op()).isEqualTo(Operation.SNAPSHOT);
        assertThat(event.isSnapshot()).isTrue();
    }

    @Test
    void parses_logical_message_event() throws Exception {
        String json = """
            {
              "payload": {
                "op": "m",
                "before": null,
                "after": null,
                "source": {"schema": "public", "table": null, "lsn": 12345, "txId": 100, "snapshot": "false"},
                "ts_ms": 1712345678000
              }
            }
            """;

        CdcEvent event = mapper.readValue(json, CdcEvent.class);

        assertThat(event.op()).isEqualTo(Operation.MESSAGE);
        assertThat(event.after()).isNull();
        assertThat(event.before()).isNull();
    }
}
