package com.example.cdc.worker;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

import com.rabbitmq.client.Channel;

import java.util.ArrayList;
import java.util.List;

/**
 * Consume la cola por lotes (spring.rabbitmq.listener.simple.batch-size) para
 * que ClickHouse reciba un INSERT por lote y no uno por evento. El ack sigue
 * siendo manual y POR MENSAJE: cada evento se confirma o va a la DLQ por su
 * cuenta, igual que cuando se consumia de a uno.
 */
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

    @RabbitListener(queues = "${cdc.rabbitmq.queue:cdc.worker}", ackMode = "MANUAL", batch = "true")
    public void onMessages(List<Message> messages, Channel channel) {
        List<Pendiente> pendientes = new ArrayList<>(messages.size());
        for (Message m : messages) {
            Object seq = m.getMessageProperties().getHeaders().get("x-seq");
            pendientes.add(new Pendiente(m, m.getMessageProperties().getDeliveryTag(),
                    seq instanceof Number n ? n.intValue() : null));
        }
        procesar(pendientes, channel);
    }

    /** Un solo mensaje: se procesa como un lote de uno. */
    public void onMessage(Message message, Channel channel, long deliveryTag, Integer seqHeader) {
        procesar(List.of(new Pendiente(message, deliveryTag, seqHeader)), channel);
    }

    private record Pendiente(Message message, long deliveryTag, Integer seq) {
    }

    private void procesar(List<Pendiente> pendientes, Channel channel) {
        List<Pendiente> enPipeline = new ArrayList<>(pendientes.size());
        List<PipelineExecutor.Evento> eventos = new ArrayList<>(pendientes.size());
        for (Pendiente p : pendientes) {
            CdcEvent event;
            try {
                event = mapper.readValue(p.message().getBody(), CdcEvent.class);
            } catch (Exception e) {
                rechazar(p.deliveryTag(), channel, null, e);
                continue;
            }
            if (event.op() == Operation.MESSAGE) {
                // Logical message from pg_logical_emit_message — already captured in audit_ctx separately.
                confirmar(p.deliveryTag(), channel);
                continue;
            }
            // lsn/xid live on the Debezium source block (authoritative) — no header indirection.
            long lsn = (event.source() != null && event.source().lsn() != null) ? event.source().lsn() : 0L;
            long xid = (event.source() != null && event.source().txId() != null) ? event.source().txId() : 0L;
            enPipeline.add(p);
            eventos.add(new PipelineExecutor.Evento(event, lsn, xid, p.seq() != null ? p.seq() : 0));
        }
        if (eventos.isEmpty()) {
            return;
        }

        List<Exception> fallos;
        try {
            fallos = pipeline.executeBatch(eventos);
        } catch (Exception inesperado) {
            // executeBatch devuelve los fallos por evento; si aun asi lanza, nada
            // del lote se da por aplicado.
            for (int i = 0; i < enPipeline.size(); i++) {
                rechazar(enPipeline.get(i).deliveryTag(), channel, eventos.get(i).event(), inesperado);
            }
            return;
        }

        for (int i = 0; i < enPipeline.size(); i++) {
            CdcEvent event = eventos.get(i).event();
            if (fallos.get(i) != null) {
                rechazar(enPipeline.get(i).deliveryTag(), channel, event, fallos.get(i));
                continue;
            }
            confirmar(enPipeline.get(i).deliveryTag(), channel);
            // Defensive: op/tsMs may be null on heartbeat or malformed events. Use "?" as a
            // placeholder tag so WorkerMetrics.incrementConsumed doesn't NPE on a null tag.
            String opCode = event.op() != null ? event.op().code() : "?";
            String tabla = event.tableName() != null ? event.tableName() : "";
            workerMetrics.incrementConsumed(tabla, opCode, "OK");
            if (event.tsMs() != null) {
                workerMetrics.setLagSeconds((System.currentTimeMillis() - event.tsMs()) / 1000);
            }
        }
    }

    private void confirmar(long deliveryTag, Channel channel) {
        try {
            channel.basicAck(deliveryTag, false);
        } catch (Exception e) {
            log.error("basicAck falló (deliveryTag={}): {}", deliveryTag, e.getMessage());
        }
    }

    private void rechazar(long deliveryTag, Channel channel, CdcEvent event, Exception causa) {
        log.error("Error procesando mensaje, enviando a DLQ", causa);
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
