package com.example.cdc.worker;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageBuilder;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static java.util.concurrent.TimeUnit.SECONDS;

/**
 * End-to-end IT against the real docker-compose stack
 * (cdc-rabbitmq, cdc-clickhouse) that the user already has running.
 * Does NOT spin up Testcontainers; reads connection info from environment
 * variables (the same ones {@code .env} exports to the production
 * containers) and points Spring at the host-port mappings declared in
 * docker-compose.yml.
 *
 * <p>Because the live cdc-worker is already consuming the
 * {@code cdc.worker} queue, publishing a properly-shaped envelope
 * here will be picked up by the running worker (NOT this test JVM),
 * parsed via {@link com.example.cdc.common.event.CdcEvent#fromJson},
 * written into {@code auditoria.audit_log}, and verifiable via a
 * follow-up HTTP SELECT.
 *
 * <p>ClickHouse is queried via its native HTTP endpoint because the
 * autowired Spring {@code JdbcTemplate} is bound to the Oracle
 * datasource (per {@code spring.datasource.*}), and wiring a second
 * bean is more code than the test warrants.
 */
@SpringBootTest(webEnvironment = WebEnvironment.NONE)
class ContextPropagationIT {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newHttpClient();

    @DynamicPropertySource
    static void overrideProps(DynamicPropertyRegistry r) {
        // Override Spring to talk to the docker-compose host bindings.
        r.add("spring.rabbitmq.host", () -> System.getProperty("rabbit.host", "localhost"));
        r.add("spring.rabbitmq.port", () -> System.getProperty("rabbit.port", "5672"));
        r.add("spring.rabbitmq.username", () -> System.getProperty("rabbit.user", "cdc"));
        r.add("spring.rabbitmq.password", () -> System.getProperty("rabbit.pass", "demopass"));

        r.add("cdc.clickhouse.url", () ->
                System.getProperty("clickhouse.url", "http://default:demopass@localhost:58123"));

        r.add("cdc.oracle.url", () -> System.getProperty("oracle.url",
                "jdbc:oracle:thin:@localhost:1521/FREEPDB1"));
        r.add("cdc.oracle.user", () -> System.getProperty("oracle.user", "ACADEMICO"));
        r.add("cdc.oracle.password", () -> System.getProperty("oracle.pass", "Academico123"));

        // ClickHouse is the only destination we verify here.
        r.add("cdc.destinations.oracle.enabled", () -> "false");
        r.add("cdc.destinations.clickhouse.enabled", () -> "true");

        // The live worker is the consumer; this JVM only publishes +
        // verifies. Suppress the @RabbitListener so the test JVM does
        // not race the live worker for messages.
        r.add("spring.rabbitmq.listener.simple.auto-startup", () -> "false");
    }

    @Autowired RabbitTemplate rabbitTemplate;

    @Test
    void context_fields_persist_to_real_clickhouse_via_real_worker() throws Exception {
        // Unique tabla name per run (epoch ms suffix) so this test does
        // not race earlier runs that landed on the live ClickHouse.
        String tabla = "tusuario_real_ctx_" + System.currentTimeMillis();

        // The seven audit_ctx fields, copied verbatim from the production
        // trigger payload (see 04-context-emitter.sql lines 18–24).
        Map<String, Object> context = Map.of(
                "app_user",   "alice.morales",
                "db_user",    "postgres",
                "sesion_id",  "S-2026-08-03-CTX-REAL",
                "familia",    "ADMIN",
                "request_id", "req-2026-08-03-real-it",
                "etiqueta",   "evaluacion_docente",
                "contexto",   Map.of("rol", "docente", "establecimiento", "E-7")
        );

        Map<String, Object> envelope = Map.of(
                "payload", Map.of(
                        "op", "c",
                        "after", Map.of("pk_tusuario", 9999, "primer_nombre", "Alice"),
                        "source", Map.of(
                                "schema", "academico_test",
                                "table",  tabla,
                                "txId",   99999L,
                                "lsn",    7000L,
                                "snapshot", "false"
                        ),
                        "ts_ms", System.currentTimeMillis()
                ),
                "routing_key", "academico_test." + tabla,
                "context", context
        );

        Message msg = MessageBuilder
                .withBody(MAPPER.writeValueAsBytes(envelope))
                .setContentType("application/json")
                .build();
        // cdc.events topic exchange routes every routing_key (#) to
        // cdc.worker. The live cdc-worker picks this up and writes
        // the audit row into ClickHouse.
        rabbitTemplate.convertAndSend("cdc.events", "academico_test." + tabla, msg);

        // Poll ClickHouse until the live worker has inserted the row.
        await().atMost(60, SECONDS).pollInterval(1, SECONDS).untilAsserted(() -> {
            Integer count = queryCount(tabla);
            assertThat(count).isGreaterThanOrEqualTo(1);
        });

        Map<String, Object> row = queryLatest(tabla);

        // Each of the seven audit_ctx columns must contain the value
        // we published. Use equality (not contains) to confirm the
        //        worker copied our payload verbatim — not "" or some
        // default.
        assertThat(row.get("app_user")).isEqualTo("alice.morales");
        assertThat(row.get("db_user")).isEqualTo("postgres");
        assertThat(row.get("sesion_id")).isEqualTo("S-2026-08-03-CTX-REAL");
        assertThat(row.get("familia")).isEqualTo("ADMIN");
        assertThat(row.get("request_id")).isEqualTo("req-2026-08-03-real-it");
        assertThat(row.get("etiqueta")).isEqualTo("evaluacion_docente");
        Object contexto = row.get("contexto");
        assertThat(contexto).asString()
                .contains("\"rol\":\"docente\"")
                .contains("\"establecimiento\":\"E-7\"");
    }

    /** SELECT count() FROM auditoria.audit_log WHERE tabla = '<tabla>'. */
    private static Integer queryCount(String tabla) throws Exception {
        String sql = "SELECT count() FROM auditoria.audit_log WHERE tabla = '" + tabla.replace("'", "''") + "'";
        String body = clickhouseQuery(sql);
        return Integer.parseInt(body.trim());
    }

    /**
     * SELECT the seven context columns from the latest row matching the
     * given tabla. Returns a {@code Map} keyed by column name.
     * ClickHouse returns TSV by default for non-JSON queries; the
     * seven columns here are all strings so we can split lines.
     */
    private static Map<String, Object> queryLatest(String tabla) throws Exception {
        String sql = "SELECT " +
                "app_user, db_user, sesion_id, familia, request_id, etiqueta, contexto " +
                "FROM auditoria.audit_log " +
                "WHERE tabla = '" + tabla.replace("'", "''") + "' " +
                "ORDER BY ts DESC LIMIT 1 FORMAT TabSeparatedWithNames";
        String body = clickhouseQuery(sql).trim();
        String[] lines = body.split("\\R", -1);
        assertThat(lines.length).as("ClickHouse response").isGreaterThanOrEqualTo(2);
        String[] cols = lines[0].split("\t");
        String[] vals = lines[1].split("\t", -1);
        assertThat(cols.length).as("column count").isEqualTo(vals.length);
        Map<String, Object> out = new java.util.LinkedHashMap<>();
        List<String> columnNames = List.of("app_user", "db_user", "sesion_id",
                "familia", "request_id", "etiqueta", "contexto");
        for (int i = 0; i < cols.length; i++) {
            String name = cols[i].trim();
            String val = i < vals.length ? vals[i].trim() : "";
            out.put(name.isEmpty() ? columnNames.get(i) : name, val);
        }
        return out;
    }

    /**
     * Run a SELECT against the live ClickHouse via its HTTP endpoint.
     * Uses {@code cdc.clickhouse.url} (or the system-property override).
     */
    private static String clickhouseQuery(String sql) throws Exception {
        String url = System.getProperty("clickhouse.url",
                "http://default:demopass@localhost:58123");
        URI endpoint = URI.create(url);
        URI queryUri = URI.create(url + "/?query=" +
                URLEncoder.encode(sql, StandardCharsets.UTF_8));

        HttpRequest.Builder req = HttpRequest.newBuilder()
                .uri(queryUri)
                .GET();
        String userInfo = endpoint.getRawUserInfo();
        if (userInfo != null && !userInfo.isBlank()) {
            String credentials = "Basic " + Base64.getEncoder()
                    .encodeToString(userInfo.getBytes(StandardCharsets.UTF_8));
            req.header("Authorization", credentials);
        }

        HttpResponse<String> resp = HTTP.send(req.build(),
                HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) {
            throw new RuntimeException("ClickHouse query failed (HTTP " +
                    resp.statusCode() + "): " + resp.body());
        }
        return resp.body();
    }
}
