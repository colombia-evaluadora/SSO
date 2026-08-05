package com.example.cdc.capture;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.MessagePostProcessor;
import org.springframework.amqp.rabbit.core.RabbitTemplate;

import java.lang.reflect.Field;
import java.lang.reflect.Proxy;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Runtime check that AmqpPublisher's op="r" guard short-circuits the publish
 * path. Lives in its own class (no Mockito) because the existing
 * AmqpPublisherContextTest relies on mocking RabbitTemplate, which Mockito 5
 * inline cannot do on Java 25 (RabbitAccessor sealed surface). Once the project
 * runs on JDK 21, both tests should coexist; for now this one carries the
 * load on Java 25.
 */
class AmqpPublisherSnapshotGuardTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void snapshot_row_is_filtered_real_insert_and_logical_message_keep_their_paths() throws Exception {
        SimpleMeterRegistry registry = new SimpleMeterRegistry();
        CounterProbe template = new CounterProbe();
        CaptureMetrics metrics = new CaptureMetrics(registry);
        AuditContextCache cache = new AuditContextCache();
        AmqpPublisher publisher = new AmqpPublisher(template, metrics, "cdc.events", cache);

        // op="r" snapshot row — must NOT be published, must increment snapshot_skipped.
        handleSingle(publisher, Map.of(
                "op", "r",
                "after", Map.of("pk_tusuario", 1, "nombre", "Alice"),
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 0, "lsn", 1, "snapshot", "true")
        ));

        // op="c" real insert — must be published, no snapshot_skipped delta.
        handleSingle(publisher, Map.of(
                "op", "c",
                "after", Map.of("pk_tusuario", 2, "nombre", "Bob"),
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 10, "lsn", 2, "snapshot", "false")
        ));

        // op="m" logical message — must NOT be published (existing behaviour).
        handleSingle(publisher, Map.of(
                "op", "m",
                "source", Map.of("schema", "public", "table", "tusuario",
                        "txId", 11, "lsn", 3, "snapshot", "false"),
                "message", Map.of("prefix", "audit_ctx",
                        "data", "{\"app_user\":\"x\",\"db_user\":\"postgres\",\"sesion_id\":\"S-1\",\"familia\":\"F\",\"request_id\":\"r\",\"etiqueta\":\"e\",\"contexto\":{}}")
        ));

        // Exactly 1 publish (op=c). Snapshot and logical-message were both filtered.
        assertThat(template.published.get())
                .as("only the real insert should reach convertAndSend")
                .isEqualTo(1);

        // snapshot_skipped counter was incremented exactly once.
        double skipped = registry.get("cdc.events.snapshot_skipped")
                .tag("tabla", "tusuario").counter().count();
        assertThat(skipped)
                .as("op='r' must call incrementSnapshotSkipped once")
                .isEqualTo(1.0);

        // The published event is the op=c one (sanity check on routing key).
        assertThat(template.lastRoutingKey).isEqualTo("public.tusuario");
    }

    @SuppressWarnings("unchecked")
    private void handleSingle(AmqpPublisher publisher, Map<String, Object> payload) throws Exception {
        String json = mapper.writeValueAsString(payload);
        ChangeEvent<String, String> ev = new ChangeEvent<String, String>() {
            public String key() { return null; }
            public String value() { return json; }
            public String destination() { return null; }
            public Integer partition() { return null; }
        };
        DebeziumEngine.RecordCommitter<ChangeEvent<String, String>> committer =
            (DebeziumEngine.RecordCommitter<ChangeEvent<String, String>>)
                (DebeziumEngine.RecordCommitter<?>) Proxy.newProxyInstance(
                    DebeziumEngine.RecordCommitter.class.getClassLoader(),
                    new Class<?>[]{DebeziumEngine.RecordCommitter.class},
                    (p, m, a) -> null);
        publisher.handleBatch(List.of(ev), committer);
    }

    /**
     * Counts convertAndSend invocations and captures the last routing key
     * without instantiating any AMQP broker connection.
     */
    private static final class CounterProbe extends RabbitTemplate {
        final AtomicInteger published = new AtomicInteger();
        volatile String lastRoutingKey;

        @Override
        public void convertAndSend(String exchange, String routingKey, Object message,
                                   MessagePostProcessor processor) {
            published.incrementAndGet();
            this.lastRoutingKey = routingKey;
        }
    }
}
