package com.example.cdc.capture;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.MessagePostProcessor;
import org.springframework.amqp.rabbit.core.RabbitTemplate;

import java.util.Map;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class AmqpPublisherTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void publishes_to_exchange_with_schema_table_routing_key() throws Exception {
        RabbitTemplate template = mock(RabbitTemplate.class);
        // Committer must be a mock (not null) because AmqpPublisher.handleBatch
        // calls committer.markProcessed(...) and committer.markBatchFinished().
        // The brief's literal "null" passes only work if AmqpPublisher skipped those calls.
        @SuppressWarnings("unchecked")
        DebeziumEngine.RecordCommitter<ChangeEvent<String, String>> committer =
            (DebeziumEngine.RecordCommitter<ChangeEvent<String, String>>)
                (DebeziumEngine.RecordCommitter<?>) mock(DebeziumEngine.RecordCommitter.class);
        CaptureMetrics metrics = mock(CaptureMetrics.class);
        AmqpPublisher publisher = new AmqpPublisher(template, metrics, "cdc.events");

        Map<String, Object> payload = Map.of(
            "op", "c",
            "after", Map.of("id", 1),
            "source", Map.of("schema", "public", "table", "clientes")
        );

        String json = mapper.writeValueAsString(payload);

        ChangeEvent<String, String> event = new ChangeEvent<String, String>() {
            public String key() { return null; }
            public String value() { return json; }
            public String destination() { return null; }
            public Integer partition() { return null; }
        };

        publisher.handleBatch(java.util.List.of(event), committer);

        // AmqpPublisher uses convertAndSend(exchange, routingKey, event, MessagePostProcessor)
        // (4-arg overload added in T16 for x-lsn / x-xid / x-seq headers).
        // Verify the routing key + exchange are derived correctly from source.schema + source.table.
        verify(template).convertAndSend(
            eq("cdc.events"),
            eq("public.clientes"),
            any(Object.class),
            any(MessagePostProcessor.class)
        );
    }
}
