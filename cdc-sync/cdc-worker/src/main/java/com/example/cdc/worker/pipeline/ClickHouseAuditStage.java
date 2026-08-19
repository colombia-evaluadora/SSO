package com.example.cdc.worker.pipeline;

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
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

@Component
public class ClickHouseAuditStage {

    private static final Logger log = LoggerFactory.getLogger(ClickHouseAuditStage.class);

    private final String clickhouseUrl;
    private final HttpClient http;
    private final ObjectMapper mapper = new ObjectMapper();

    public ClickHouseAuditStage(@Value("${cdc.clickhouse.url}") String clickhouseUrl) {
        this.clickhouseUrl = clickhouseUrl;
        this.http = HttpClient.newHttpClient();
    }

    public void execute(AuditRecord record) throws Exception {
        String sql = "INSERT INTO auditoria.audit_log FORMAT JSONEachRow";
        String body = mapper.writeValueAsString(toRow(record));

        URI uri = URI.create(clickhouseUrl + "/?query=" +
                java.net.URLEncoder.encode(sql, StandardCharsets.UTF_8));

        HttpRequest.Builder request = HttpRequest.newBuilder()
                .uri(uri)
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .header("Content-Type", "application/json");
        URI endpoint = URI.create(clickhouseUrl);
        String userInfo = endpoint.getUserInfo();
        if (userInfo != null) {
            request.header("Authorization", "Basic " + Base64.getEncoder().encodeToString(
                    userInfo.getBytes(StandardCharsets.UTF_8)));
        }
        HttpRequest req = request.build();

        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) {
            throw new RuntimeException("ClickHouse insert failed: " + resp.statusCode() + " " + resp.body());
        }
        log.debug("audit_log insert OK tabla={} pk={}", record.tabla(), record.pk());
    }

    private Map<String, Object> toRow(AuditRecord r) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("lsn", r.lsn());
        row.put("seq", r.seq());
        row.put("xid", r.xid());
        row.put("tabla", r.tabla());
        row.put("operacion", r.operacion());
        row.put("pk", r.pk());
        row.put("fila_new", r.filaNew() != null ? r.filaNew() : Map.of());
        row.put("fila_old", r.filaOld() != null ? r.filaOld() : Map.of());
        row.put("tabla_origen", r.tablaOrigen() != null ? r.tablaOrigen() : "");
        row.put("estado", r.estado());
        row.put("latencia_ms", r.latenciaMs());
        row.put("snapshot", r.snapshot() ? "true" : "false");
        row.put("app_user", r.appUser());
        row.put("db_user", r.dbUser());
        row.put("sesion_id", r.sesionId());
        row.put("familia", r.familia() != null ? r.familia() : "");
        row.put("request_id", r.requestId());
        row.put("http_method", r.httpMethod() != null ? r.httpMethod() : "");
        row.put("etiqueta", r.etiqueta() != null ? r.etiqueta() : "");
        row.put("contexto", r.contextoJson() != null ? r.contextoJson() : "");
        row.put("ts", java.time.LocalDateTime.now(java.time.ZoneOffset.UTC).toString().replace('T', ' '));
        return row;
    }
}
