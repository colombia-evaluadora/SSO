package com.example.cdc.common.event;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Map;

@JsonIgnoreProperties(ignoreUnknown = true)
public record CdcEvent(
        @JsonProperty("op") Operation op,
        @JsonProperty("before") Map<String, Object> before,
        @JsonProperty("after") Map<String, Object> after,
        @JsonProperty("source") Source source,
        @JsonProperty("ts_ms") Long tsMs,
        @JsonProperty("routing_key") String routingKey,
        @JsonProperty("context") Context context,
        @JsonProperty("message") Message message
) {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    /**
     * Debezium RabbitMQ messages wrap the CDC payload under a {@code payload} key
     * while connector metadata such as {@code routing_key} stays at the top level.
     * This factory unwraps that envelope so the record's canonical constructor can
     * receive flat fields.
     */
    @JsonCreator
    public static CdcEvent fromJson(JsonNode root) {
        JsonNode payload = root != null ? root.get("payload") : null;
        String routingKey = (root != null && root.hasNonNull("routing_key"))
                ? root.get("routing_key").asText()
                : null;
        // "context" lives at the envelope root (set by AmqpPublisher), not inside payload.
        Context context = toContext(root != null ? root.get("context") : null);
        // "message" (Debezium logical message from pg_logical_emit_message)
        // lives inside the Debezium "payload" block.
        Message message = toMessage(payload != null ? payload.get("message") : null);

        if (payload == null || payload.isNull()) {
            return new CdcEvent(null, null, null, null, null, routingKey, context, message);
        }

        Operation op = null;
        JsonNode opNode = payload.get("op");
        if (opNode != null && !opNode.isNull()) {
            op = Operation.fromCode(opNode.asText());
        }

        Map<String, Object> before = toMap(payload.get("before"));
        Map<String, Object> after = toMap(payload.get("after"));
        Source source = toSource(payload.get("source"));
        Long tsMs = toLong(payload.get("ts_ms"));

        return new CdcEvent(op, before, after, source, tsMs, routingKey, context, message);
    }

    private static Map<String, Object> toMap(JsonNode node) {
        if (node == null || node.isNull()) return null;
        return MAPPER.convertValue(node, Map.class);
    }

    private static Long toLong(JsonNode node) {
        if (node == null || node.isNull()) return null;
        return node.asLong();
    }

    private static String toText(JsonNode node) {
        if (node == null || node.isNull()) return null;
        return node.asText();
    }

    private static Source toSource(JsonNode node) {
        if (node == null || node.isNull()) return null;
        return new Source(
                toText(node.get("db")),
                toText(node.get("schema")),
                toText(node.get("table")),
                node.hasNonNull("txId") ? node.get("txId").asLong() : null,
                node.hasNonNull("lsn") ? node.get("lsn").asLong() : null,
                toText(node.get("snapshot"))
        );
    }

    private static Context toContext(JsonNode node) {
        if (node == null || node.isNull()) return null;
        return new Context(
                toText(node.get("app_user")),
                toText(node.get("db_user")),
                toText(node.get("sesion_id")),
                toText(node.get("familia")),
                toText(node.get("request_id")),
                toText(node.get("http_method")),
                toText(node.get("client_ip")),
                toText(node.get("user_agent")),
                toMap(node.get("headers")),
                toMap(node.get("request_body")),
                toText(node.get("etiqueta")),
                toMap(node.get("contexto"))
        );
    }

    private static Message toMessage(JsonNode node) {
        if (node == null || node.isNull()) return null;
        // Debezium emits the logical-message payload as a string blob under
        // message.data — keep its raw form so callers can parse themselves
        // (the trigger formats audit_ctx as JSON, but other prefixes may vary).
        String data = toText(node.get("data"));
        return new Message(toText(node.get("prefix")), data);
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Source(
            String db,
            String schema,
            String table,
            @JsonProperty("txId") Long txId,
            Long lsn,
            String snapshot
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Context(
            @JsonProperty("app_user") String appUser,
            @JsonProperty("db_user") String dbUser,
            @JsonProperty("sesion_id") String sesionId,
            @JsonProperty("familia") String familia,
            @JsonProperty("request_id") String requestId,
            @JsonProperty("http_method") String httpMethod,
            // V-audit-ctx-2 — transporte HTTP para auditoría de seguridad.
            // headers/requestBody llegan ya como Map (fn_audit_ctx los
            // castea a json en Postgres) igual que `contexto`.
            @JsonProperty("client_ip") String clientIp,
            @JsonProperty("user_agent") String userAgent,
            Map<String, Object> headers,
            @JsonProperty("request_body") Map<String, Object> requestBody,
            String etiqueta,
            Map<String, Object> contexto
    ) {}

    /**
     * Debezium logical message (emitted via {@code pg_logical_emit_message}).
     * Always paired with {@link Operation#MESSAGE}.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Message(
            String prefix,
            String data
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public boolean isInsert() { return op == Operation.INSERT; }
    public boolean isUpdate() { return op == Operation.UPDATE; }
    public boolean isDelete() { return op == Operation.DELETE; }
    public boolean isSnapshot() { return op == Operation.SNAPSHOT; }
    public boolean isLogicalMessage() { return op == Operation.MESSAGE; }

    public String tableName() {
        return source != null ? source.table() : null;
    }

    public String schemaName() {
        return source != null ? source.schema() : null;
    }

    public boolean isSnapshotEvent() {
        return source != null && "true".equals(source.snapshot());
    }
}
