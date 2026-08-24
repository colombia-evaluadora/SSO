package com.co.eurekatic.ssoadmin.client;

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
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Optional;

/**
 * V-audit-revert — lectura de {@code auditoria.audit_log} vía la
 * interfaz HTTP de ClickHouse. Mismo patrón que {@code
 * ClickHouseAuditStage} en cdc-worker (Basic auth embebido en la URL,
 * {@code HttpClient} plano) pero de solo lectura — este servicio nunca
 * escribe en ClickHouse, solo consulta el cambio que se va a revertir
 * en Postgres.
 */
@Component
public class ClickHouseAuditClient {

    private final String clickhouseUrl;
    private final HttpClient http;
    private final ObjectMapper mapper = new ObjectMapper();

    public ClickHouseAuditClient(@Value("${sso.clickhouse.url:http://cdc-clickhouse:8123}") String clickhouseUrl) {
        this.clickhouseUrl = clickhouseUrl;
        this.http = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();
    }

    /**
     * Busca la fila de {@code audit_log} identificada por
     * {@code (lsn, seq)} — la clave que unívocamente identifica UN
     * evento de cambio de fila (no una transacción completa). Devuelve
     * vacío si no existe.
     */
    public Optional<AuditLogRow> findByLsnSeq(long lsn, long seq) {
        String sql = "SELECT tabla, operacion, pk, request_id, etiqueta, "
                + "app_user, fila_new_raw, fila_old_raw "
                + "FROM auditoria.audit_log "
                + "WHERE lsn = " + lsn + " AND seq = " + seq + " "
                + "ORDER BY ts DESC LIMIT 1 FORMAT JSONEachRow";
        List<JsonNode> rows = query(sql);
        if (rows.isEmpty()) return Optional.empty();
        JsonNode row = rows.get(0);
        return Optional.of(new AuditLogRow(
                row.path("tabla").asText(""),
                row.path("operacion").asText(""),
                row.path("pk").asText(""),
                row.path("request_id").asText(""),
                row.path("etiqueta").asText(""),
                row.path("app_user").asText(""),
                row.path("fila_new_raw").asText(""),
                row.path("fila_old_raw").asText("")
        ));
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

        List<JsonNode> out = new ArrayList<>();
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

    /** Proyección mínima de una fila de {@code audit_log} para el revert. */
    public record AuditLogRow(
            String tabla,
            String operacion,
            String pk,
            String requestId,
            String etiqueta,
            String appUser,
            String filaNewRawJson,
            String filaOldRawJson
    ) {}
}
