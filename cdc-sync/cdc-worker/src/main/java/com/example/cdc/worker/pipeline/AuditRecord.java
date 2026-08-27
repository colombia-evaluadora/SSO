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
        String appUserId,      // V-audit-ctx-3 — PK crudo de TUSUARIO, texto hasta el borde de ClickHouse (ver ClickHouseAuditStage.toRow)
        String dbUser,
        String sesionId,
        String familia,        // extraído de contexto.familia (ruta path-of-least-resistance)
        String requestId,
        String httpMethod,     // verbo HTTP del request que originó el cambio (PUT/POST/PATCH/...)
        String clientIp,       // V-audit-ctx-2 — IP del cliente (X-Forwarded-For o conexión directa)
        String userAgent,
        Map<String, Object> headers,    // whitelist curada, va directo a un ClickHouse Map — no se serializa
        String requestBodyJson,         // body/params del caller, redactado — serializado como contexto
        String etiqueta,
        String contextoJson,
        // V-audit-revert — copia CRUDA de event.after()/event.before(),
        // ANTES de que JsonTypedRowBuilder los proyecte a los slots
        // tipados de filaNew/filaOld. Necesaria porque el algoritmo
        // "primer slot gana" de JsonTypedRowBuilder puede colapsar dos
        // columnas reales bajo el mismo nombre genérico (p.ej. "codigo"),
        // perdiendo el nombre de columna real de la que perdió el slot —
        // sin este raw no hay forma confiable de reconstruir un
        // UPDATE/INSERT/DELETE de reversión.
        String filaNewRawJson,
        String filaOldRawJson
) {
    private static final ObjectMapper MAPPER = new ObjectMapper()
            .registerModule(new com.fasterxml.jackson.datatype.jsr310.JavaTimeModule())
            // ISO-8601, no timestamps numéricos — fila_new_raw/fila_old_raw
            // deben quedar legibles para reconstruir SQL a mano si hace falta.
            .disable(com.fasterxml.jackson.databind.SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

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
                event.context() != null ? event.context().appUserId() : "",
                event.context() != null ? event.context().dbUser() : "",
                event.context() != null ? event.context().sesionId() : "",
                familia,
                event.context() != null ? event.context().requestId() : "",
                event.context() != null ? event.context().httpMethod() : "",
                event.context() != null ? event.context().clientIp() : "",
                event.context() != null ? event.context().userAgent() : "",
                event.context() != null ? event.context().headers() : Map.of(),
                serializeJson(event.context() == null ? null : event.context().requestBody()),
                event.context() != null ? event.context().etiqueta() : "",
                serializeJson(event.context() == null ? null : event.context().contexto()),
                // Crudo — antes del builder, no después. filaNew/filaOld de
                // arriba SÍ pasan por el builder (para los slots tipados);
                // esto es event.after()/event.before() tal cual llegó de
                // Debezium, columna real -> valor, sin colisiones de slot.
                serializeJson(event.after()),
                serializeJson(event.before())
        );
    }

    /**
     * JSON-serialize a context map so ClickHouse stores valid JSON instead
     * of {@link Map#toString()}'s {@code key=value} debug format. Triggered
     * by the production data check that revealed contexto was previously
     * emitted as Java Map debug notation. Reused for both {@code contexto}
     * and {@code request_body} — same "opaque JSON blob in a String column"
     * shape, unlike {@code headers} which maps to a real ClickHouse Map.
     */
    private static String serializeJson(Map<String, Object> map) {
        if (map == null || map.isEmpty()) return "";
        try {
            return MAPPER.writeValueAsString(map);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to serialize JSON context field", e);
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
