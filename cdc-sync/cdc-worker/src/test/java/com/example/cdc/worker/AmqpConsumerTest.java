package com.example.cdc.worker;

import com.rabbitmq.client.Channel;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageProperties;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

class AmqpConsumerTest {

    @Test
    void acknowledges_logical_messages_without_executing_pipeline() throws Exception {
        PipelineExecutor pipeline = mock(PipelineExecutor.class);
        WorkerMetrics metrics = mock(WorkerMetrics.class);
        Channel channel = mock(Channel.class);
        AmqpConsumer consumer = new AmqpConsumer(pipeline, metrics);
        Message message = new Message("""
                {
                  "payload": {
                    "op": "m",
                    "before": null,
                    "after": null,
                    "source": {"schema": "public", "table": null, "lsn": 12345, "txId": 100, "snapshot": "false"},
                    "ts_ms": 1712345678000
                  }
                }
                """.getBytes(), new MessageProperties());

        consumer.onMessage(message, channel, 99L, null);

        verify(channel).basicAck(99L, false);
        verify(pipeline, never()).execute(any(), anyLong(), anyLong(), anyInt());
    }

    private static Message mensaje(long tag, long lsn) {
        MessageProperties props = new MessageProperties();
        props.setDeliveryTag(tag);
        return new Message(("""
                {
                  "payload": {
                    "op": "c",
                    "before": null,
                    "after": {"codigo": "X"},
                    "source": {"schema": "academico_test", "table": "tdepartamento", "lsn": %d, "txId": 100, "snapshot": "false"},
                    "ts_ms": 1712345678000
                  }
                }
                """.formatted(lsn)).getBytes(), props);
    }

    @Test
    void batch_acks_and_rejects_each_message_on_its_own() throws Exception {
        PipelineExecutor pipeline = mock(PipelineExecutor.class);
        WorkerMetrics metrics = mock(WorkerMetrics.class);
        Channel channel = mock(Channel.class);
        AmqpConsumer consumer = new AmqpConsumer(pipeline, metrics);
        java.util.List<Exception> resultado = new java.util.ArrayList<>();
        resultado.add(null);
        resultado.add(new RuntimeException("ORA-00904"));
        resultado.add(null);
        org.mockito.Mockito.when(pipeline.executeBatch(org.mockito.ArgumentMatchers.anyList())).thenReturn(resultado);

        consumer.onMessages(java.util.List.of(mensaje(1, 10), mensaje(2, 11), mensaje(3, 12)), channel);

        verify(pipeline, org.mockito.Mockito.times(1)).executeBatch(org.mockito.ArgumentMatchers.anyList());
        verify(channel).basicAck(1L, false);
        verify(channel).basicReject(2L, false);
        verify(channel).basicAck(3L, false);
    }

    @Test
    void unparseable_message_goes_to_dlq_without_stopping_the_batch() throws Exception {
        PipelineExecutor pipeline = mock(PipelineExecutor.class);
        WorkerMetrics metrics = mock(WorkerMetrics.class);
        Channel channel = mock(Channel.class);
        AmqpConsumer consumer = new AmqpConsumer(pipeline, metrics);
        java.util.List<Exception> ok = new java.util.ArrayList<>();
        ok.add(null);
        org.mockito.Mockito.when(pipeline.executeBatch(org.mockito.ArgumentMatchers.anyList())).thenReturn(ok);
        MessageProperties props = new MessageProperties();
        props.setDeliveryTag(7L);

        consumer.onMessages(java.util.List.of(new Message("no es json".getBytes(), props), mensaje(8, 20)), channel);

        verify(channel).basicReject(7L, false);
        verify(channel).basicAck(8L, false);
    }
}
