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
}
