package com.example.cdc.worker.pipeline;

import com.example.cdc.audit.Slot;
import com.example.cdc.common.event.CdcEvent;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Map;
import java.util.StringJoiner;

public record AuditRecord(
        long lsn,
        int seq,
        long xid,
        String tabla,
        String operacion,
        String pk,
        Map<String, Object> filaNew,
        Map<String, Object> filaOld,
        String tablaOrigen,    // tabla Oracle destino (nullable)
        String estado,         // "OK" | "WARN" | "ERROR" | "DLQ"
        long latenciaMs,
        boolean snapshot,
        String appUser,
        String dbUser,
        String sesionId,
        String familia,        // extraído de contexto.familia (ruta path-of-least-resistance)
        String requestId,
        String httpMethod,     // verbo HTTP del request que originó el cambio (PUT/POST/PATCH/...)
        String etiqueta,
        String contextoJson
) {
    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static AuditRecord fromEvent(CdcEvent event, int seq, long lsn, long xid,
                                        String tablaOrigen, String estado,
                                        long latenciaMs,
                                        JsonTypedRowBuilder builder) {
        // familia lives as a top-level field on CdcEvent.Context (the cdc-capture
        // audit_ctx payload emits it that way). Fall back to contexto["familia"]
        // for events whose envelope pre-dates the cdc-capture correlation
        // rewrite (e.g. replayed from an older RabbitMQ topic).
        String familia = "";
        if (event.context() != null && event.context().familia() != null
                && !event.context().familia().isEmpty()) {
            familia = event.context().familia();
        } else if (event.context() != null && event.context().contexto() != null
                && event.context().contexto().get("familia") != null) {
            familia = event.context().contexto().get("familia").toString();
        }

        String tabla = event.tableName();
        Map<String, Object> filaNew =
                (builder == null || event.after() == null) ? event.after()
                                                           : builder.build(tabla, event.after());
        Map<String, Object> filaOld =
                (builder == null || event.before() == null) ? event.before()
                                                            : builder.build(tabla, event.before());

        return new AuditRecord(
                lsn,
                seq,
                xid,
                tabla,
                event.op() != null ? event.op().code() : "r",
                extractPk(filaNew, filaOld),
                filaNew,
                filaOld,
                tablaOrigen,
                estado,
                latenciaMs,
                event.isSnapshotEvent(),
                event.context() != null ? event.context().appUser() : "",
                event.context() != null ? event.context().dbUser() : "",
                event.context() != null ? event.context().sesionId() : "",
                familia,
                event.context() != null ? event.context().requestId() : "",
                event.context() != null ? event.context().httpMethod() : "",
                event.context() != null ? event.context().etiqueta() : "",
                serializeContexto(event.context() == null ? null : event.context().contexto())
        );
    }

    /**
     * JSON-serialize the contexto map so ClickHouse stores valid JSON instead
     * of {@link Map#toString()}'s {@code key=value} debug format. Triggered
     * by the production data check that revealed contexto was previously
     * emitted as Java Map debug notation.
     */
    private static String serializeContexto(Map<String, Object> contexto) {
        if (contexto == null || contexto.isEmpty()) return "";
        try {
            return MAPPER.writeValueAsString(contexto);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to serialize contexto", e);
        }
    }

    private static String extractPk(Map<String, Object> after, Map<String, Object> before) {
        Map<String, Object> source = after != null ? after : before;
        if (source == null) return "";

        StringJoiner joiner = new StringJoiner(",");
        boolean found = false;
        for (Map.Entry<String, Object> entry : source.entrySet()) {
            String key = entry.getKey().toLowerCase();
            // Ignore canonical pk_t to avoid '42,42' duplication; the original
            // pk_<name> key is preserved by JsonTypedRowBuilder.
            if (key.startsWith("pk_") && !key.equals(Slot.PK_T.code())) {
                joiner.add(String.valueOf(entry.getValue()));
                found = true;
            }
        }
        if (found) return joiner.toString();

        return String.valueOf(source.hashCode());
    }
}
