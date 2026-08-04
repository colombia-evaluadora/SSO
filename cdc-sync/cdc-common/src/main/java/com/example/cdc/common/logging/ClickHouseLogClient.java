package com.example.cdc.common.logging;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

public class ClickHouseLogClient {

    private static final Logger log = LoggerFactory.getLogger(ClickHouseLogClient.class);
    private static final ObjectMapper mapper = new ObjectMapper();

    private final String clickhouseUrl;
    private final HttpClient http = HttpClient.newHttpClient();
    private final ThreadPoolExecutor executor = new ThreadPoolExecutor(
            1, 2, 60, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(1000),
            r -> { Thread t = new Thread(r, "ch-log-writer"); t.setDaemon(true); return t; }
    );

    public ClickHouseLogClient(String clickhouseUrl) {
        this.clickhouseUrl = clickhouseUrl;
    }

    public void appendAsync(String nivel, String servicio, String logger,
                            String mensaje, String excepcion, Map<String, Object> contexto) {
        executor.submit(() -> {
            try {
                Map<String, Object> row = Map.of(
                        "ts", Instant.now().toString(),
                        "nivel", nivel,
                        "servicio", servicio,
                        "logger", logger,
                        "mensaje", mensaje,
                        "excepcion", excepcion != null ? excepcion : "",
                        "contexto", contexto != null ? contexto.toString() : ""
                );
                String body = mapper.writeValueAsString(row);
                String sql = "INSERT INTO auditoria.app_log FORMAT JSONEachRow";

                URI uri = URI.create(clickhouseUrl + "/?query=" + URLEncoder.encode(sql, StandardCharsets.UTF_8));
                HttpRequest req = HttpRequest.newBuilder()
                        .uri(uri)
                        .POST(HttpRequest.BodyPublishers.ofString(body))
                        .header("Content-Type", "application/json")
                        .build();
                HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
                if (resp.statusCode() != 200) {
                    log.warn("ClickHouse app_log insert failed: {} {}", resp.statusCode(), resp.body());
                }
            } catch (Exception e) {
                log.warn("Error escribiendo app_log: {}", e.getMessage());
            }
        });
    }

    public void shutdown() {
        executor.shutdown();
        try {
            if (!executor.awaitTermination(5, TimeUnit.SECONDS)) {
                executor.shutdownNow();
            }
        } catch (InterruptedException e) {
            executor.shutdownNow();
        }
    }
}
