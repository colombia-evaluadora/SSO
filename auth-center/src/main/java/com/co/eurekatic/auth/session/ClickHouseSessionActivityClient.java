package com.co.eurekatic.auth.session;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.StringJoiner;

/**
 * V-audit-ctx-4 (sesiones reales) — lectura de solo-actividad de
 * {@code auditoria.audit_log} vía la interfaz HTTP de ClickHouse.
 * Mismo patrón que {@code ClickHouseAuditClient} en sso-admin (Basic
 * auth embebido en la URL, {@code HttpClient} plano, sin dependencias
 * nuevas) — usado por {@link SessionReaperService} para saber cuándo
 * fue la última actividad real de cada sesión abierta, sin tener que
 * escribir un timestamp de "última actividad" en Postgres en CADA
 * escritura de negocio (eso costaría un UPDATE extra por request; acá
 * el costo es una sola consulta batch por ciclo del reaper).
 */
@Component
public class ClickHouseSessionActivityClient {

    private final String clickhouseUrl;
    private final HttpClient http;
    private final ObjectMapper mapper = new ObjectMapper();

    public ClickHouseSessionActivityClient(@Value("${sso.clickhouse.url:http://cdc-clickhouse:8123}") String clickhouseUrl) {
        this.clickhouseUrl = clickhouseUrl;
        this.http = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();
    }

    /**
     * Último {@code ts} conocido en {@code audit_log} para cada
     * {@code sesion_id} de {@code familyIds} que SÍ tuvo alguna
     * escritura auditada. Las familias sin ninguna fila (sesiones de
     * solo lectura, o de negocio pero contra tablas sin trigger) no
     * aparecen en el resultado — el llamante debe caer a
     * {@code started_at} de Postgres para esas.
     *
     * <p>Nota: hoy {@code sesion_id} no está poblado por ningún
     * escritor todavía (requiere que el JWT lleve el {@code familyId}
     * como claim y que cada servicio lo propague a
     * {@code app.contexto.sesion_id} — trabajo de seguimiento fuera
     * de este cambio). Este método queda listo y correcto para
     * cuando eso exista; hasta entonces siempre devuelve un mapa
     * vacío y el reaper cae al fallback de {@code started_at} para
     * TODAS las sesiones, que sigue siendo correcto (solo menos
     * preciso que usar la última escritura real).
     */
    public Map<String, Instant> lastActivityBySessionId(Collection<String> familyIds) {
        if (familyIds == null || familyIds.isEmpty()) {
            return Map.of();
        }
        StringJoiner in = new StringJoiner(",");
        for (String id : familyIds) {
            in.add("'" + id.replace("'", "''") + "'");
        }
        String sql = "SELECT sesion_id, max(ts) AS last_ts FROM auditoria.audit_log "
                + "WHERE sesion_id IN (" + in + ") GROUP BY sesion_id FORMAT JSONEachRow";

        Map<String, Instant> out = new LinkedHashMap<>();
        for (JsonNode row : query(sql)) {
            String sesionId = row.path("sesion_id").asText("");
            String lastTs = row.path("last_ts").asText("");
            if (sesionId.isEmpty() || lastTs.isEmpty()) continue;
            // ClickHouse DateTime64 vía JSONEachRow sale como
            // "yyyy-MM-dd HH:mm:ss.SSS" (espacio, no 'T') en UTC —
            // mismo formato que ClickHouseAuditStage escribe.
            out.put(sesionId, Instant.parse(lastTs.replace(' ', 'T') + "Z"));
        }
        return out;
    }

    private List<JsonNode> query(String sql) {
        URI uri = URI.create(clickhouseUrl + "/?query=" +
                java.net.URLEncoder.encode(sql, StandardCharsets.UTF_8));

        HttpRequest.Builder request = HttpRequest.newBuilder()
                .uri(uri)
                .timeout(Duration.ofSeconds(10))
                .GET();
        URI endpoint = URI.create(clickhouseUrl);
        String userInfo = endpoint.getUserInfo();
        if (userInfo != null) {
            request.header("Authorization", "Basic " + Base64.getEncoder().encodeToString(
                    userInfo.getBytes(StandardCharsets.UTF_8)));
        }

        HttpResponse<String> resp;
        try {
            resp = http.send(request.build(), HttpResponse.BodyHandlers.ofString());
        } catch (HttpTimeoutException e) {
            throw new IllegalStateException("ClickHouse no respondió a tiempo", e);
        } catch (Exception e) {
            throw new IllegalStateException("No se pudo consultar ClickHouse: " + e.getMessage(), e);
        }
        if (resp.statusCode() != 200) {
            throw new IllegalStateException("ClickHouse query failed: " + resp.statusCode() + " " + resp.body());
        }

        List<JsonNode> out = new java.util.ArrayList<>();
        for (String line : resp.body().split("\n")) {
            if (line.isBlank()) continue;
            try {
                out.add(mapper.readTree(line));
            } catch (Exception e) {
                throw new IllegalStateException("Respuesta de ClickHouse no es JSON válido: " + line, e);
            }
        }
        return out;
    }
}
