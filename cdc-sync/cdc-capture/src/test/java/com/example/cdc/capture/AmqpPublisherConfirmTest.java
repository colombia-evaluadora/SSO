package com.example.cdc.capture;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessagePostProcessor;
import org.springframework.amqp.core.ReturnedMessage;
import org.springframework.amqp.rabbit.connection.CorrelationData;
import org.springframework.amqp.rabbit.core.RabbitTemplate;

import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Publisher confirms: el offset solo avanza si el broker confirma todo el lote. */
class AmqpPublisherConfirmTest {

    private final ObjectMapper mapper = new ObjectMapper();

    private static final class Probe extends RabbitTemplate {
        final Consumer<CorrelationData> onSend;

        Probe(Consumer<CorrelationData> onSend) {
            this.onSend = onSend;
        }

        @Override
        public void convertAndSend(String exchange, String routingKey, Object message,
                                   MessagePostProcessor processor, CorrelationData cd) {
            onSend.accept(cd);
        }
    }

    private ChangeEvent<String, String> event(int id) throws Exception {
        String json = mapper.writeValueAsString(Map.of(
                "op", "c",
                "after", Map.of("id", id),
                "source", Map.of("schema", "public", "table", "clientes", "txId", 0, "lsn", id)));
        return new ChangeEvent<>() {
            public String key() { return null; }
            public String value() { return json; }
            public String destination() { return null; }
            public Integer partition() { return null; }
        };
    }

    @SuppressWarnings("unchecked")
    private DebeziumEngine.RecordCommitter<ChangeEvent<String, String>> committer(List<String> calls) {
        return (DebeziumEngine.RecordCommitter<ChangeEvent<String, String>>)
                (DebeziumEngine.RecordCommitter<?>) Proxy.newProxyInstance(
                        DebeziumEngine.RecordCommitter.class.getClassLoader(),
                        new Class<?>[]{DebeziumEngine.RecordCommitter.class},
                        (p, m, a) -> { calls.add(m.getName()); return null; });
    }

    private AmqpPublisher publisher(Consumer<CorrelationData> onSend, long timeoutMs) {
        return new AmqpPublisher(new Probe(onSend), new CaptureMetrics(new SimpleMeterRegistry()),
                "cdc.events", new AuditContextCache(), timeoutMs);
    }

    @Test
    void all_acked_marks_processed() throws Exception {
        List<String> calls = new ArrayList<>();
        publisher(cd -> cd.getFuture().complete(new CorrelationData.Confirm(true, null)), 500)
                .handleBatch(List.of(event(1), event(2)), committer(calls));
        assertThat(calls).containsExactly("markProcessed", "markBatchFinished");
    }

    @Test
    void nack_throws_and_does_not_mark_processed() {
        List<String> calls = new ArrayList<>();
        AmqpPublisher p = publisher(cd -> cd.getFuture().complete(new CorrelationData.Confirm(false, "boom")), 500);
        assertThatThrownBy(() -> p.handleBatch(List.of(event(1)), committer(calls)))
                .isInstanceOf(InterruptedException.class).hasMessageContaining("nack");
        assertThat(calls).isEmpty();
    }

    @Test
    void returned_message_throws() {
        List<String> calls = new ArrayList<>();
        AmqpPublisher p = publisher(cd -> {
            cd.setReturned(new ReturnedMessage(new Message(new byte[0]), 312, "NO_ROUTE",
                    "cdc.events", "public.clientes"));
            cd.getFuture().complete(new CorrelationData.Confirm(true, null));
        }, 500);
        assertThatThrownBy(() -> p.handleBatch(List.of(event(1)), committer(calls)))
                .isInstanceOf(InterruptedException.class).hasMessageContaining("returned");
        assertThat(calls).isEmpty();
    }

    @Test
    void missing_confirm_times_out() {
        List<String> calls = new ArrayList<>();
        AmqpPublisher p = publisher(cd -> { }, 100);
        assertThatThrownBy(() -> p.handleBatch(List.of(event(1)), committer(calls)))
                .isInstanceOf(InterruptedException.class).hasMessageContaining("timeout");
        assertThat(calls).isEmpty();
    }
}
