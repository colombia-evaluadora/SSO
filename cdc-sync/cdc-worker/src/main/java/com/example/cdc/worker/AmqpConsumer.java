package com.example.cdc.worker;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.support.AmqpHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Component;

import com.rabbitmq.client.Channel;

@Component
public class AmqpConsumer {

    private static final Logger log = LoggerFactory.getLogger(AmqpConsumer.class);

    private final ObjectMapper mapper = new ObjectMapper();
    private final PipelineExecutor pipeline;
    private final WorkerMetrics workerMetrics;

    public AmqpConsumer(PipelineExecutor pipeline, WorkerMetrics workerMetrics) {
        this.pipeline = pipeline;
        this.workerMetrics = workerMetrics;
    }

    @RabbitListener(queues = "${cdc.rabbitmq.queue:cdc.worker}", ackMode = "MANUAL")
    public void onMessage(Message message, Channel channel,
                          @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag,
                          @Header(name = "x-seq", required = false) Integer seqHeader) throws Exception {
        CdcEvent event = null;
        try {
            event = mapper.readValue(message.getBody(), CdcEvent.class);
            if (event.op() == Operation.MESSAGE) {
                // Logical message from pg_logical_emit_message — already captured in audit_ctx separately.
                channel.basicAck(deliveryTag, false);
                return;
            }
            // lsn/xid live on the Debezium source block (authoritative) — no header indirection.
            long lsn = (event.source() != null && event.source().lsn() != null) ? event.source().lsn() : 0L;
            long xid = (event.source() != null && event.source().txId() != null) ? event.source().txId() : 0L;
            int seq = seqHeader != null ? seqHeader : 0;
            pipeline.execute(event, lsn, xid, seq);
            channel.basicAck(deliveryTag, false);
            // Defensive: op/tsMs may be null on heartbeat or malformed events. Use "?" as a
            // placeholder tag so WorkerMetrics.incrementConsumed doesn't NPE on a null tag.
            String opCode = event.op() != null ? event.op().code() : "?";
            String tabla = event.tableName() != null ? event.tableName() : "";
            workerMetrics.incrementConsumed(tabla, opCode, "OK");
            if (event.tsMs() != null) {
                workerMetrics.setLagSeconds((System.currentTimeMillis() - event.tsMs()) / 1000);
            }
        } catch (Exception e) {
            log.error("Error procesando mensaje, enviando a DLQ", e);
            String tabla = (event != null && event.tableName() != null) ? event.tableName() : "";
            workerMetrics.incrementConsumed(tabla, "?", "DLQ");
            workerMetrics.incrementDlq();
            try {
                channel.basicReject(deliveryTag, false);  // sin requeue → DLQ
            } catch (Exception rejectEx) {
                log.error("basicReject falló (deliveryTag={}): {}", deliveryTag, rejectEx.getMessage());
            }
        }
    }
}