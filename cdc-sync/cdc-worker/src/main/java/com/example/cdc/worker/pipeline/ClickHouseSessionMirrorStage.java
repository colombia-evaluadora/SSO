package com.example.cdc.worker.pipeline;

import com.example.cdc.common.event.CdcEvent;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Mirror stage para {@code academico_test.tsesion_web} -- replica
 * cada INSERT/UPDATE/DELETE de la tabla de sesiones a una tabla
 * ClickHouse con la misma forma, para que /audits/* pueda consultar
 * la fuente de sesiones reales (V90) sin acoplar ClickHouse a la
 * red de Postgres.
 *
 * <p>Por qué un stage aparte y no reusar {@link ClickHouseAuditStage}:
 * la tabla destino NO es {@code auditoria.audit_log} (que es el log
 * append-only de auditoría), sino una tabla espejo que refleja el
 * estado actual de cada sesión. Las dos tablas viven en paralelo en
 * ClickHouse: {@code audit_log} tiene una fila por evento (incluido
 * el audit_ctx de cada cambio), {@code tsesion_web} tiene una fila
 * por sesión con su estado más reciente.
 *
 * <p>Cómo se enruta: {@link com.example.cdc.worker.PipelineExecutor}
 * detecta la tabla por nombre ({@code "academico_test.tsesion_web"}
 * después de la normalización del schema) y, además del
 * {@link ClickHouseAuditStage} que sigue corriendo para mantener
 * {@code audit_log} consistente con el resto del pipeline, invoca
 * este stage. El mirror se hace en INSERT/UPDATE/DELETE por
 * {@code family_id} (la clave lógica), no por pk_tsesion_web (la
 * surrogate) -- ReplacingMergeTree con ORDER BY (family_id) deduplica
 * si llega un INSERT viejo después de un UPDATE más nuevo.
 */
@Component
public class ClickHouseSessionMirrorStage {

    private static final Logger log = LoggerFactory.getLogger(ClickHouseSessionMirrorStage.class);

    private final String clickhouseUrl;
    private final HttpClient http;
    private final ObjectMapper mapper = new ObjectMapper();

    public ClickHouseSessionMirrorStage(@Value("${cdc.clickhouse.url}") String clickhouseUrl) {
        this.clickhouseUrl = clickhouseUrl;
        this.http = HttpClient.newHttpClient();
    }

    /**
     * Aplica el evento al mirror. La columna {@code after} del evento
     * trae el estado POST-cambio para INSERT/UPDATE; la columna
     * {@code before} trae el estado PRE-cambio para UPDATE/DELETE.
     * Para DELETE mandamos un ALTER explicito con todas las columnas
     * en sus valores por defecto (la fila desaparece con
     * ReplacingMergeTree al compactar).
     */
    public void execute(CdcEvent event, long lsn) throws Exception {
        String op = event.op() != null ? event.op().code() : "r";
        switch (op) {
            case "c", "u" -> upsert(event.after(), lsn);
            case "d" -> deleteByFamilyId(familyIdOf(event.before()));
            default -> log.debug("SessionMirrorStage: op={} no aplica (snapshot/truncate?)", op);
        }
    }

    private void upsert(Map<String, Object> after, long lsn) {
        if (after == null || after.isEmpty()) {
            log.warn("SessionMirrorStage: upsert con after vacío, se ignora");
            return;
        }
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("family_id", str(after.get("family_id")));
        row.put("pk_tsesion_web", asLong(after.get("pk_tsesion_web")));
        row.put("fk_tusuario", asLong(after.get("fk_tusuario")));
        row.put("started_at", asDateTime(after.get("started_at")));
        row.put("ended_at", asDateTimeOrNull(after.get("ended_at")));
        row.put("last_seen_at", asDateTimeOrNull(after.get("last_seen_at")));
        row.put("close_reason", str(after.get("close_reason")));
        // BUG real encontrado revisando esto: antes iba hardcodeado a 0
        // para TODA fila -- con eso argMax(..., lsn) en V90/V92 no
        // puede distinguir "la versión más nueva" de ninguna otra (todas
        // empatan en 0), así que el dedupe que V92 existe para resolver
        // quedaba roto en la práctica pese a que la query ya lo pedía
        // bien. El lsn real del evento Debezium SÍ crece monótonamente
        // por transacción, que es justo lo que argMax necesita.
        row.put("lsn", lsn);
        send("INSERT INTO auditoria.tsesion_web FORMAT JSONEachRow", row);
    }

    private void deleteByFamilyId(String familyId) {
        if (familyId == null || familyId.isEmpty()) {
            log.warn("SessionMirrorStage: delete sin family_id en before, se ignora");
            return;
        }
        // ALTER DELETE explícito. ReplacingMergeTree ya deduplica por
        // family_id, pero un DELETE deja la fila fuera del result set
        // inmediatamente, sin esperar a la compactación.
        String sql = "ALTER TABLE auditoria.tsesion_web DELETE WHERE family_id = '"
                + familyId.replace("'", "''") + "'";
        sendRaw(sql);
    }

    private static String familyIdOf(Map<String, Object> before) {
        if (before == null) return null;
        Object v = before.get("family_id");
        return v == null ? null : v.toString();
    }

    private void send(String sql, Map<String, Object> row) {
        try {
            String body = mapper.writeValueAsString(row);
            sendInternal(sql, body);
        } catch (Exception e) {
            throw new RuntimeException("SessionMirrorStage: no se pudo serializar la fila", e);
        }
    }

    private void sendRaw(String sql) {
        sendInternal(sql, null);
    }

    private void sendInternal(String sql, String body) {
        URI uri = URI.create(clickhouseUrl + "/?query="
                + java.net.URLEncoder.encode(sql, StandardCharsets.UTF_8));

        HttpRequest.Builder builder = HttpRequest.newBuilder()
                .uri(uri)
                .timeout(java.time.Duration.ofSeconds(10));
        if (body != null) {
            builder.POST(HttpRequest.BodyPublishers.ofString(body))
                   .header("Content-Type", "application/json");
        } else {
            builder.POST(HttpRequest.BodyPublishers.noBody());
        }

        URI endpoint = URI.create(clickhouseUrl);
        String userInfo = endpoint.getUserInfo();
        if (userInfo != null) {
            builder.header("Authorization", "Basic " + Base64.getEncoder().encodeToString(
                    userInfo.getBytes(StandardCharsets.UTF_8)));
        }

        try {
            HttpResponse<String> resp = http.send(builder.build(), HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() != 200) {
                throw new RuntimeException("ClickHouse mirror failed: " + resp.statusCode() + " " + resp.body());
            }
            log.debug("tsesion_web mirror OK family_id={}", body != null && body.contains("family_id") ? "<set>" : "<delete>");
        } catch (Exception e) {
            throw new RuntimeException("ClickHouse mirror send failed", e);
        }
    }

    private static String str(Object v) {
        return v == null ? "" : v.toString();
    }

    private static Long asLong(Object v) {
        if (v == null) return null;
        if (v instanceof Number n) return n.longValue();
        try {
            return Long.parseLong(v.toString());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /**
     * ClickHouse espera DateTime64 como 'yyyy-MM-dd HH:mm:ss.SSS'
     * (espacio, no 'T'). Postgres llega por Debezium como ISO-8601 con
     * 'T' y zona, o ya en formato con espacio (microsegundos según
     * la config de Debezium). Normalizamos a la forma que ClickHouse
     * parsea sin ambigüedad.
     */
    private static String asDateTime(Object v) {
        if (v == null) return null;
        String s = v.toString();
        // ISO-8601 con 'T' → 'yyyy-MM-dd HH:mm:ss.SSS'
        if (s.endsWith("Z")) s = s.substring(0, s.length() - 1);
        int t = s.indexOf('T');
        if (t >= 0) s = s.substring(0, t) + " " + s.substring(t + 1);
        // ClickHouse DateTime64(3,'UTC') trunca a milisegundos
        int dot = s.indexOf('.');
        if (dot >= 0 && s.length() > dot + 4) s = s.substring(0, dot + 4);
        // LocalDateTime necesita 'T' para parsear -- reinsertamos
        // DESPUÉS de truncar a milisegundos. ClickHouse acepta ambas
        // formas ('T' o espacio), así que este formato es seguro.
        int t2 = s.indexOf(' ');
        if (t2 >= 0) s = s.substring(0, t2) + "T" + s.substring(t2 + 1);
        return LocalDateTime.parse(s).atZone(ZoneOffset.UTC).toLocalDateTime().toString();
    }

    private static String asDateTimeOrNull(Object v) {
        if (v == null) return null;
        return asDateTime(v);
    }
}
