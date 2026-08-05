package com.example.cdc.capture;

import com.example.cdc.common.event.CdcEvent;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Component
public class AmqpPublisher implements DebeziumEngine.ChangeConsumer<ChangeEvent<String, String>> {

    private static final Logger log = LoggerFactory.getLogger(AmqpPublisher.class);

    /** Logical-message prefix emitted by the BEFORE STATEMENT trigger in 04-context-emitter.sql. */
    private static final String AUDIT_CTX_PREFIX = "audit_ctx";

    private final RabbitTemplate rabbitTemplate;
    private final CaptureMetrics captureMetrics;
    private final String exchange;
    private final AuditContextCache ctxCache;
    private final ObjectMapper mapper = new ObjectMapper();

    @Autowired
    public AmqpPublisher(RabbitTemplate rabbitTemplate,
                         CaptureMetrics captureMetrics,
                         @org.springframework.beans.factory.annotation.Value("${cdc.rabbitmq.exchange}") String exchange) {
        this(rabbitTemplate, captureMetrics, exchange, new AuditContextCache());
    }

    /** Visible for tests so they can inject a cache with a small TTL / size. */
    public AmqpPublisher(RabbitTemplate rabbitTemplate,
                         CaptureMetrics captureMetrics,
                         String exchange,
                         AuditContextCache ctxCache) {
        this.rabbitTemplate = rabbitTemplate;
        this.captureMetrics = captureMetrics;
        this.exchange = exchange;
        this.ctxCache = ctxCache;
    }

    @Override
    public void handleBatch(List<ChangeEvent<String, String>> records,
                            DebeziumEngine.RecordCommitter<ChangeEvent<String, String>> committer)
            throws InterruptedException {
        for (ChangeEvent<String, String> record : records) {
            if (record.value() == null) continue;
            try {
                Map<String, Object> event = parseEvent(record.value());
                Map<String, Object> source = (Map<String, Object>) event.get("source");
                if (source == null) continue;

                String schema = (String) source.getOrDefault("schema", "public");
                String table = (String) source.get("table");
                String routingKey = schema + "." + table;
                long lsn = ((Number) source.getOrDefault("lsn", 0)).longValue();
                long xid = ((Number) source.getOrDefault("txId", 0)).longValue();
                int seq = records.indexOf(record);

                String op = (String) event.get("op");

                // Logical-message event from pg_logical_emit_message: stash the
                // payload into the per-xid cache so the subsequent row events
                // of the same transaction can lift it. Do NOT publish a row to
                // the exchange — the worker has nothing to do with these.
                if ("m".equals(op)) {
                    CdcEvent.Context ctx = parseAuditContext(event);
                    if (ctx != null && xid != 0L) {
                        ctxCache.put(xid, ctx);
                        captureMetrics.incrementPublished(table, op);
                    } else {
                        log.debug("Ignoring audit_ctx logical message xid={}", xid);
                    }
                    continue;
                }

                // Debezium snapshot row (op="r", emitted during the initial SELECT *
                // bootstrap or after a force-snapshot reset). These are NOT business
                // changes — drop them at the producer so they never reach the worker,
                // never get written to auditoria.audit_log, and never trigger the
                // ColumnRenamer snapshot branch in Oracle.
                if ("r".equals(op)) {
                    captureMetrics.incrementSnapshotSkipped(table);
                    log.debug("Skipping snapshot row table={} lsn={}", table, lsn);
                    continue;
                }

                // Row-change event: lift the cached context (if any) and attach
                // it to the envelope so the worker can populate audit_log.
                CdcEvent.Context ctx = (xid != 0L) ? ctxCache.take(xid) : null;

                // Envelope {payload, routing_key, context} — the raw Debezium row change
                // goes under "payload" while routing_key/context stay at the top level so
                // CdcEvent.fromJson can lift them out (avoids empty user fields in audit_log).
                Map<String, Object> envelope = new LinkedHashMap<>();
                envelope.put("payload", event);
                envelope.put("routing_key", routingKey);
                if (ctx != null) {
                    envelope.put("context", contextToMap(ctx));
                }

                rabbitTemplate.convertAndSend(exchange, routingKey, envelope, m -> {
                    m.getMessageProperties().setHeader("x-lsn", lsn);
                    m.getMessageProperties().setHeader("x-xid", xid);
                    m.getMessageProperties().setHeader("x-seq", seq);
                    return m;
                });
                captureMetrics.incrementPublished(table, op);
            } catch (Exception e) {
                log.error("Error publicando evento a RabbitMQ", e);
                throw new InterruptedException("publish failed: " + e.getMessage());
            }
        }
        committer.markProcessed(records.get(records.size() - 1));
        committer.markBatchFinished();
    }

    private Map<String, Object> parseEvent(String json) throws Exception {
        return mapper.readValue(json, HashMap.class);
    }

    /** Parses an audit_ctx logical-message body into the per-xid context cache value. */
    private CdcEvent.Context parseAuditContext(Map<String, Object> deb) {
        Object msgObj = deb.get("message");
        if (!(msgObj instanceof Map<?, ?> msg)) return null;
        Object prefix = msg.get("prefix");
        if (!AUDIT_CTX_PREFIX.equals(prefix)) return null;

        Object data = msg.get("data");
        if (!(data instanceof String payload) || payload.isBlank()) return null;

        Map<String, Object> body;
        try {
            body = mapper.readValue(payload, new TypeReference<Map<String, Object>>() {});
        } catch (Exception e) {
            log.warn("No se pudo parsear audit_ctx payload: {}", e.getMessage());
            return null;
        }

        Object contextoRaw = body.get("contexto");
        Map<String, Object> contextoMap = (contextoRaw instanceof Map<?, ?> cmap)
                ? toStringKeyedMap(cmap)
                : null;

        return new CdcEvent.Context(
                str(body.get("app_user")),
                str(body.get("db_user")),
                str(body.get("sesion_id")),
                str(body.get("familia")),
                str(body.get("request_id")),
                str(body.get("etiqueta")),
                contextoMap
        );
    }

    /** Copies non-null context fields into the envelope representation. */
    private static Map<String, Object> contextToMap(CdcEvent.Context ctx) {
        Map<String, Object> m = new LinkedHashMap<>();
        if (ctx.appUser() != null) m.put("app_user", ctx.appUser());
        if (ctx.dbUser() != null) m.put("db_user", ctx.dbUser());
        if (ctx.sesionId() != null) m.put("sesion_id", ctx.sesionId());
        if (ctx.familia() != null) m.put("familia", ctx.familia());
        if (ctx.requestId() != null) m.put("request_id", ctx.requestId());
        if (ctx.etiqueta() != null) m.put("etiqueta", ctx.etiqueta());
        if (ctx.contexto() != null) m.put("contexto", ctx.contexto());
        return m;
    }

    private static String str(Object o) {
        return (o == null) ? null : o.toString();
    }

    /** Coerce a Map with arbitrary key types to a Map&lt;String, Object&gt;. */
    private static Map<String, Object> toStringKeyedMap(Map<?, ?> in) {
        Map<String, Object> out = new LinkedHashMap<>(in.size());
        for (Map.Entry<?, ?> e : in.entrySet()) {
            out.put(String.valueOf(e.getKey()), e.getValue());
        }
        return out;
    }

    /** Test accessor for the cache. */
    AuditContextCache getContextCache() {
        return ctxCache;
    }
}
