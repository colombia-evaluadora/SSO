package com.co.eurekatic.comms;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.amqp.rabbit.core.RabbitAdmin;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.client.standard.StandardWebSocketClient;
import org.springframework.web.socket.handler.TextWebSocketHandler;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.RabbitMQContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Contrato REST del chat (mock del front) y protocolo del socket contra
 * Postgres (V560 real), Redis y RabbitMQ en contenedores.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "comms.jwt.secret=" + CommsIntegrationTest.SECRETO, "eureka.client.enabled=false"})
@Testcontainers
class CommsIntegrationTest {

    static final String SECRETO = "secreto-de-pruebas-de-al-menos-32-bytes-para-hs256";
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newHttpClient();
    private static final JwtTokenService JWT = new JwtTokenService(new JwtProperties(
            null, "-", "sso-postgres", 3600, 3600, "Authorization", "Bearer ", SECRETO));

    @Container
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    @Container
    static final RabbitMQContainer RABBIT = new RabbitMQContainer("rabbitmq:3.13.7-management");
    @Container
    @SuppressWarnings("resource")
    static final GenericContainer<?> REDIS = new GenericContainer<>("redis:7-alpine").withExposedPorts(6379);

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        r.add("spring.datasource.username", POSTGRES::getUsername);
        r.add("spring.datasource.password", POSTGRES::getPassword);
        r.add("spring.data.redis.host", REDIS::getHost);
        r.add("spring.data.redis.port", () -> REDIS.getMappedPort(6379));
        r.add("spring.rabbitmq.host", RABBIT::getHost);
        r.add("spring.rabbitmq.port", RABBIT::getAmqpPort);
        r.add("spring.rabbitmq.username", RABBIT::getAdminUsername);
        r.add("spring.rabbitmq.password", RABBIT::getAdminPassword);
    }

    @Value("${local.server.port}") int port;
    @Autowired JdbcClient jdbc;
    @Autowired RabbitTemplate rabbit;

    static long ana;
    static long luis;
    static long sofi;

    @BeforeAll
    static void esquema() throws Exception {
        var ds = new org.springframework.jdbc.datasource.DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        var j = JdbcClient.create(ds);
        try (var c = ds.getConnection(); var st = c.createStatement()) {
            st.execute(new String(CommsIntegrationTest.class.getResourceAsStream("/esquema-base.sql").readAllBytes()));
            st.execute(Files.readString(Path.of("../postgres/migrations/V560__comunicaciones_chat_ddl.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V561__comunicaciones_outbox_eventos.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V561.1__comunicaciones_outbox_registrar.sql")));
            // Re-aplicar (como hace el deploy al editar) debe ser idempotente.
            st.execute(Files.readString(Path.of("../postgres/migrations/V560__comunicaciones_chat_ddl.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V561__comunicaciones_outbox_eventos.sql")));
        }
        ana = usuario(j, "ana@colegio.edu.co", "Ana Rios", "CEVAL-DOCENTE");
        luis = usuario(j, "luis@colegio.edu.co", "Luis Paz", "CEVAL-DOCENTE");
        sofi = usuario(j, "sofi@colegio.edu.co", "Sofia Gil", "CEVAL-ESTUDIANTE");
    }

    private static long usuario(JdbcClient j, String email, String nombre, String rol) {
        long id = j.sql("INSERT INTO users (username, full_name, email) VALUES (:e, :n, :e) RETURNING id_user")
                .param("e", email).param("n", nombre).query(Long.class).single();
        j.sql("INSERT INTO role (name) VALUES (:r) ON CONFLICT DO NOTHING").param("r", rol).update();
        j.sql("INSERT INTO role_users SELECT :u, id_role FROM role WHERE name = :r").param("u", id).param("r", rol).update();
        return id;
    }

    private String token(String email, long id, String rol) {
        return JWT.issueAccessToken(email, id, null, Set.of(rol), "COLEGIO DEMO", email.substring(0, 4));
    }

    @Test
    void chatDeExtremoAExtremoConTiempoRealYNotificaciones() throws Exception {
        String tAna = token("ana@colegio.edu.co", ana, "CEVAL-DOCENTE");
        String tLuis = token("luis@colegio.edu.co", luis, "CEVAL-DOCENTE");
        String tSofi = token("sofi@colegio.edu.co", sofi, "CEVAL-ESTUDIANTE");

        // Cola de prueba para ver los eventos que van a notification-service.
        var admin = new RabbitAdmin(rabbit.getConnectionFactory());
        TopicExchange notif = new TopicExchange("notifications", true, false);
        Queue cola = QueueBuilder.nonDurable("prueba.eventos").build();
        admin.declareExchange(notif);
        admin.declareQueue(cola);
        admin.declareBinding(BindingBuilder.bind(cola).to(notif).with("evento"));

        // Politica: el estudiante no crea canales; el docente no le escribe DM.
        assertThat(post("/comunicaciones/conversaciones", tSofi, Map.of("NOMBRE", "x")).statusCode()).isEqualTo(403);
        assertThat(post("/comunicaciones/directos", tAna, Map.of("FK_PERSONA", sofi)).statusCode()).isEqualTo(403);

        JsonNode canal = rows(post("/comunicaciones/conversaciones", tAna,
                Map.of("NOMBRE", "Area de matematicas", "CATEGORIA", "GENERAL", "MIEMBROS", List.of(luis)))).get(0);
        long id = canal.get("id").asLong();
        assertThat(canal.get("esCreador").asBoolean()).isTrue();
        assertThat(canal.get("totalMiembros").asInt()).isEqualTo(2);
        assertThat(post("/comunicaciones/conversaciones", tAna, Map.of("NOMBRE", "area de MATEMATICAS")).statusCode())
                .isEqualTo(409);
        assertThat(get("/comunicaciones/conversaciones/" + id + "/mensajes", tSofi).statusCode()).isEqualTo(404);

        // Socket de Luis suscrito al canal.
        BlockingQueue<JsonNode> recibidos = new LinkedBlockingQueue<>();
        WebSocketSession ws = abrir(tLuis, recibidos);
        ws.sendMessage(new TextMessage("{\"type\":\"subscribe\",\"topic\":\"canal:" + id + "\"}"));
        JsonNode sub = esperar(recibidos, "subscribed");
        assertThat(sub.get("topic").asText()).isEqualTo("canal:" + id);
        ws.sendMessage(new TextMessage("{\"type\":\"subscribe\",\"topic\":\"user:ana@colegio.edu.co\"}"));
        assertThat(esperar(recibidos, "error").get("code").asText()).isEqualTo("forbidden");

        // Ana menciona a Luis: mensaje en vivo + notificacion CHAT_MENCION.
        String clientId = java.util.UUID.randomUUID().toString();
        var body = Map.of("TEXTO", "Hola <@" + luis + "> revisa esto", "CLIENT_MESSAGE_ID", clientId);
        JsonNode m = rows(post("/comunicaciones/conversaciones/" + id + "/mensajes", tAna, body)).get(0);
        assertThat(m.get("esPropio").asBoolean()).isTrue();
        assertThat(m.get("menciones").get(0).get("usuarioId").asLong()).isEqualTo(luis);
        // Reintento idempotente.
        assertThat(rows(post("/comunicaciones/conversaciones/" + id + "/mensajes", tAna, body)).get(0).get("id").asLong())
                .isEqualTo(m.get("id").asLong());

        JsonNode ev = esperar(recibidos, "event");
        assertThat(ev.get("event").asText()).isEqualTo("mensaje.creado");
        assertThat(ev.get("seq").asLong()).isEqualTo(sub.get("seq").asLong() + 1);
        assertThat(ev.get("data").get("esPropio").asBoolean()).isFalse();

        var notifMsg = rabbit.receiveAndConvert("prueba.eventos", 5000);
        JsonNode evento = JSON.valueToTree(notifMsg);
        assertThat(evento.get("tipo").asText()).isEqualTo("CHAT_MENCION");
        assertThat(evento.get("destinatarios").get(0).asText()).isEqualTo("luis@colegio.edu.co");
        assertThat(evento.get("deepLink").asText()).startsWith("/app/comunicaciones/chat?canal=" + id);
        // Llego por el outbox: la fila queda marcada como publicada.
        org.awaitility.Awaitility.await().atMost(5, TimeUnit.SECONDS).until(() -> jdbc.sql(
                "SELECT COUNT(*) FROM comunicaciones.toutbox_evento WHERE publicado_en IS NOT NULL")
                .query(Long.class).single() > 0);

        // Luis ve el no leido y la mencion, reacciona y lee.
        JsonNode conv = rows(get("/comunicaciones/conversaciones", tLuis)).get(0);
        assertThat(conv.get("noLeidos").asInt()).isEqualTo(1);
        assertThat(conv.get("menciones").asInt()).isEqualTo(1);
        JsonNode lista = rows(get("/comunicaciones/conversaciones/" + id + "/mensajes", tLuis));
        JsonNode delLuis = lista.get(lista.size() - 1);
        assertThat(delLuis.get("meMenciona").asBoolean()).isTrue();
        JsonNode reaccion = rows(post("/comunicaciones/mensajes/" + m.get("id").asLong() + "/reacciones", tLuis,
                Map.of("EMOJI", "👍"))).get(0).get("reacciones").get(0);
        assertThat(reaccion.get("mia").asBoolean()).isTrue();
        assertThat(reaccion.get("usuarios").get(0).asLong()).isEqualTo(luis);
        assertThat(rows(patch("/comunicaciones/conversaciones/" + id + "/leido", tLuis, Map.of())).get(0)
                .get("noLeidos").asInt()).isZero();

        // Solo el autor edita; reanudar desde un seq conocido devuelve lo que falta.
        assertThat(patch("/comunicaciones/mensajes/" + m.get("id").asLong(), tLuis, Map.of("TEXTO", "x")).statusCode())
                .isEqualTo(403);
        long visto = ev.get("seq").asLong();
        ws.close();
        rows(patch("/comunicaciones/mensajes/" + m.get("id").asLong(), tAna, Map.of("TEXTO", "editado")));
        recibidos.clear();
        WebSocketSession ws2 = abrir(tLuis, recibidos);
        ws2.sendMessage(new TextMessage("{\"type\":\"resume\",\"topic\":\"canal:" + id + "\",\"afterSeq\":" + visto + "}"));
        JsonNode reanudado = esperar(recibidos, "event");
        assertThat(reanudado.get("seq").asLong()).isEqualTo(visto + 1);
        ws2.sendMessage(new TextMessage("{\"type\":\"resume\",\"topic\":\"canal:" + id + "\",\"afterSeq\":-5}"));
        ws2.sendMessage(new TextMessage("{\"type\":\"ping\"}"));
        assertThat(esperar(recibidos, "pong")).isNotNull();
        ws2.close();

        // Ticket de un solo uso: el segundo intento cierra con 4001.
        String ticket = JSON.readTree(post("/comms/ws-ticket", tLuis, Map.of()).body()).get("ticket").asText();
        CompletableFuture<Integer> cierre = new CompletableFuture<>();
        var h = new TextWebSocketHandler() {
            @Override
            public void afterConnectionClosed(WebSocketSession s, CloseStatus status) {
                cierre.complete(status.getCode());
            }
        };
        new StandardWebSocketClient().execute(h, "ws://localhost:" + port + "/comms/ws?ticket=" + ticket).get(5, TimeUnit.SECONDS).close();
        new StandardWebSocketClient().execute(h, "ws://localhost:" + port + "/comms/ws?ticket=" + ticket).get(5, TimeUnit.SECONDS);
        assertThat(cierre.get(5, TimeUnit.SECONDS)).isIn(1000, 4001);
    }

    @Test
    void sinTokenEs401() throws Exception {
        var r = HTTP.send(HttpRequest.newBuilder(URI.create("http://localhost:" + port + "/comunicaciones/conversaciones"))
                .GET().build(), HttpResponse.BodyHandlers.ofString());
        assertThat(r.statusCode()).isEqualTo(401);
    }

    private WebSocketSession abrir(String token, BlockingQueue<JsonNode> recibidos) throws Exception {
        String ticket = JSON.readTree(post("/comms/ws-ticket", token, Map.of()).body()).get("ticket").asText();
        return new StandardWebSocketClient().execute(new TextWebSocketHandler() {
            @Override
            protected void handleTextMessage(WebSocketSession s, TextMessage msg) throws Exception {
                recibidos.add(JSON.readTree(msg.getPayload()));
            }
        }, "ws://localhost:" + port + "/comms/ws?ticket=" + ticket).get(5, TimeUnit.SECONDS);
    }

    private static JsonNode esperar(BlockingQueue<JsonNode> q, String tipo) throws InterruptedException {
        long fin = System.currentTimeMillis() + 5000;
        while (System.currentTimeMillis() < fin) {
            JsonNode n = q.poll(200, TimeUnit.MILLISECONDS);
            if (n != null && tipo.equals(n.path("type").asText())) return n;
        }
        throw new AssertionError("No llego " + tipo);
    }

    private JsonNode rows(HttpResponse<String> r) throws Exception {
        assertThat(r.statusCode()).as(r.body()).isEqualTo(200);
        return JSON.readTree(r.body()).get("rows");
    }

    private HttpResponse<String> get(String path, String token) throws Exception {
        return send("GET", path, token, null);
    }

    private HttpResponse<String> post(String path, String token, Object body) throws Exception {
        return send("POST", path, token, body);
    }

    private HttpResponse<String> patch(String path, String token, Object body) throws Exception {
        return send("PATCH", path, token, body);
    }

    private HttpResponse<String> send(String method, String path, String token, Object body) throws Exception {
        var b = HttpRequest.newBuilder(URI.create("http://localhost:" + port + path))
                .header("Authorization", "Bearer " + token).header("Content-Type", "application/json")
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody()
                        : HttpRequest.BodyPublishers.ofString(JSON.writeValueAsString(body)));
        return HTTP.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }
}
