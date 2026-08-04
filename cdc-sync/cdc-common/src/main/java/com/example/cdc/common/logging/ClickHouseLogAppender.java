package com.example.cdc.common.logging;

import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.AppenderBase;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

public class ClickHouseLogAppender extends AppenderBase<ILoggingEvent> {

    private String clickhouseUrl;
    private String servicio;
    private final ObjectMapper mapper = new ObjectMapper();
    private final ThreadPoolExecutor executor = new ThreadPoolExecutor(
            1, 2, 60, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(500),
            r -> { Thread t = new Thread(r, "ch-log-appender"); t.setDaemon(true); return t; }
    );

    public void setClickhouseUrl(String clickhouseUrl) { this.clickhouseUrl = clickhouseUrl; }
    public void setServicio(String servicio) { this.servicio = servicio; }

    @Override
    protected void append(ILoggingEvent event) {
        if (!event.getLevel().toString().equals("WARN") &&
            !event.getLevel().toString().equals("ERROR") &&
            !event.getLevel().toString().equals("FATAL")) {
            return;  // solo WARN/ERROR/FATAL van a app_log
        }

        executor.submit(() -> {
            try {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("ts", Instant.ofEpochMilli(event.getTimeStamp()).toString());
                row.put("nivel", event.getLevel().toString());
                row.put("servicio", servicio);
                row.put("logger", event.getLoggerName());
                row.put("mensaje", event.getFormattedMessage());
                row.put("excepcion", event.getThrowableProxy() != null
                        ? event.getThrowableProxy().getMessage() : "");

                String body = mapper.writeValueAsString(row);
                String sql = "INSERT INTO auditoria.app_log FORMAT JSONEachRow";
                String url = clickhouseUrl + "/?query=" +
                        java.net.URLEncoder.encode(sql, java.nio.charset.StandardCharsets.UTF_8);

                java.net.http.HttpRequest req = java.net.http.HttpRequest.newBuilder()
                        .uri(java.net.URI.create(url))
                        .POST(java.net.http.HttpRequest.BodyPublishers.ofString(body))
                        .header("Content-Type", "application/json")
                        .build();
                java.net.http.HttpClient.newHttpClient().send(req,
                        java.net.http.HttpResponse.BodyHandlers.discarding());
            } catch (Exception e) {
                // No fallar el thread principal si ClickHouse no responde
                addWarn("Error enviando log a ClickHouse: " + e.getMessage());
            }
        });
    }
}