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

import java.nio.charset.StandardCharsets;
import java.util.Base64;
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

    /**
     * Parses an audit_ctx logical-message body into the per-xid context cache value.
     *
     * <p>Debezium's {@code LogicalDecodingMessageMonitor} (verified against the
     * decompiled {@code debezium-connector-postgres-3.1.0.Final} constants
     * {@code DEBEZIUM_LOGICAL_DECODING_MESSAGE_PREFIX_KEY="prefix"} and
     * {@code DEBEZIUM_LOGICAL_DECODING_MESSAGE_CONTENT_KEY="content"}) puts the
     * message body under the key {@code content}, NOT {@code data} — this method
     * previously read the wrong key, which meant {@code parseAuditContext} always
     * returned {@code null} and every audit_ctx message was silently dropped,
     * regardless of what the caller set in {@code app.*} GUCs. See
     * docs/etiqueta-auditoria-cdc-analisis.md §11 for the end-to-end evidence
     * that surfaced this.
     *
     * <p>The value under {@code content} is also not plain text: with the default
     * {@code binary.handling.mode=bytes}, Debezium hands Kafka Connect a raw byte
     * array under a {@code Schema.BYTES} field, and the schemaless
     * {@code JsonConverter} serializes {@code BYTES} as a Base64 string — so the
     * JSON payload built by {@code fn_audit_ctx()} (04-context-emitter.sql) has to
     * be Base64-decoded before it can be parsed.
     */
    private CdcEvent.Context parseAuditContext(Map<String, Object> deb) {
        Object msgObj = deb.get("message");
        if (!(msgObj instanceof Map<?, ?> msg)) return null;
        Object prefix = msg.get("prefix");
        if (!AUDIT_CTX_PREFIX.equals(prefix)) return null;

        Object contentObj = msg.get("content");
        if (!(contentObj instanceof String base64) || base64.isBlank()) return null;

        String payload;
        try {
            payload = new String(Base64.getDecoder().decode(base64), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            log.warn("audit_ctx content no es base64 valido: {}", e.getMessage());
            return null;
        }

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
        Object headersRaw = body.get("headers");
        Map<String, Object> headersMap = (headersRaw instanceof Map<?, ?> hmap)
                ? toStringKeyedMap(hmap)
                : null;
        Object requestBodyRaw = body.get("request_body");
        Map<String, Object> requestBodyMap = (requestBodyRaw instanceof Map<?, ?> bmap)
                ? toStringKeyedMap(bmap)
                : null;

        return new CdcEvent.Context(
                str(body.get("app_user")),
                str(body.get("db_user")),
                str(body.get("sesion_id")),
                str(body.get("familia")),
                str(body.get("request_id")),
                str(body.get("http_method")),
                str(body.get("client_ip")),
                str(body.get("user_agent")),
                headersMap,
                requestBodyMap,
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
        if (ctx.httpMethod() != null) m.put("http_method", ctx.httpMethod());
        if (ctx.clientIp() != null) m.put("client_ip", ctx.clientIp());
        if (ctx.userAgent() != null) m.put("user_agent", ctx.userAgent());
        if (ctx.headers() != null) m.put("headers", ctx.headers());
        if (ctx.requestBody() != null) m.put("request_body", ctx.requestBody());
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
