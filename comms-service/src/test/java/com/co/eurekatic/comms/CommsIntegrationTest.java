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
            st.execute(Files.readString(Path.of("../postgres/migrations/V575__comunicaciones_chat_borradores_votaciones_ddl.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V585__comunicaciones_foros_ddl.sql")));
            // Re-aplicar (como hace el deploy al editar) debe ser idempotente.
            st.execute(Files.readString(Path.of("../postgres/migrations/V560__comunicaciones_chat_ddl.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V561__comunicaciones_outbox_eventos.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V575__comunicaciones_chat_borradores_votaciones_ddl.sql")));
            st.execute(Files.readString(Path.of("../postgres/migrations/V585__comunicaciones_foros_ddl.sql")));
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
    void foroConPublicacionesRespuestasYModeracion() throws Exception {
        // Personas propias: el test del chat no ve este foro en su lista de conversaciones.
        long ana = usuario(jdbc, "ana.foro@colegio.edu.co", "Ana Foro", "CEVAL-DOCENTE");
        long luis = usuario(jdbc, "luis.foro@colegio.edu.co", "Luis Foro", "CEVAL-DOCENTE");
        long sofi = usuario(jdbc, "sofi.foro@colegio.edu.co", "Sofia Foro", "CEVAL-ESTUDIANTE");
        String tAna = token("ana.foro@colegio.edu.co", ana, "CEVAL-DOCENTE");
        String tLuis = token("luis.foro@colegio.edu.co", luis, "CEVAL-DOCENTE");
        String tSofi = token("sofi.foro@colegio.edu.co", sofi, "CEVAL-ESTUDIANTE");
        var admin = new RabbitAdmin(rabbit.getConnectionFactory());
        TopicExchange notif = new TopicExchange("notifications", true, false);
        Queue cola = QueueBuilder.nonDurable("prueba.foros").build();
        admin.declareExchange(notif);
        admin.declareQueue(cola);
        admin.declareBinding(BindingBuilder.bind(cola).to(notif).with("evento"));

        long foro = rows(post("/comunicaciones/conversaciones", tAna, Map.of("NOMBRE", "Dudas de ciencias",
                "TIPO", "FORO", "MIEMBROS", List.of(luis, sofi)))).get(0).get("id").asLong();
        String base = "/comunicaciones/foros/" + foro;
        // Un foro no recibe mensajes sueltos del chat.
        assertThat(post("/comunicaciones/conversaciones/" + foro + "/mensajes", tAna, Map.of("TEXTO", "hola"))
                .statusCode()).isEqualTo(400);
        assertThat(rows(get(base, tAna)).get(0).get("puedeModerar").asBoolean()).isTrue();
        JsonNode cabSofi = rows(get(base, tSofi)).get(0);
        assertThat(cabSofi.get("puedeModerar").asBoolean()).isFalse();
        assertThat(cabSofi.get("puedePublicar").asBoolean()).isTrue();

        // Etiquetas: solo la moderacion las crea; "Anuncio" solo la pone la moderacion.
        assertThat(post(base + "/etiquetas", tSofi, Map.of("NOMBRE", "Tarea")).statusCode()).isEqualTo(403);
        long tarea = rows(post(base + "/etiquetas", tAna, Map.of("NOMBRE", "Tarea", "COLOR", "GREEN")))
                .get(0).get("id").asLong();
        long anuncio = rows(post(base + "/etiquetas", tAna, Map.of("NOMBRE", "Anuncio", "SOLO_MODERADORES", "S")))
                .get(0).get("id").asLong();

        BlockingQueue<JsonNode> recibidos = new LinkedBlockingQueue<>();
        WebSocketSession ws = abrir(tLuis, recibidos);
        ws.sendMessage(new TextMessage("{\"type\":\"subscribe\",\"topic\":\"foro:" + foro + "\"}"));
        esperar(recibidos, "subscribed");

        assertThat(post(base + "/publicaciones", tSofi, Map.of("TITULO", "x", "TEXTO", "y",
                "ETIQUETAS", List.of(anuncio))).statusCode()).isEqualTo(403);
        var cuerpo = Map.of("TITULO", "Como funciona la fotosintesis",
                "TEXTO", "No entiendo que hacen las plantas con la luz", "ETIQUETAS", List.of(tarea),
                "CLIENT_MESSAGE_ID", java.util.UUID.randomUUID().toString());
        JsonNode pub = rows(post(base + "/publicaciones", tSofi, cuerpo)).get(0);
        long pid = pub.get("id").asLong();
        // Reintento idempotente.
        assertThat(rows(post(base + "/publicaciones", tSofi, cuerpo)).get(0).get("id").asLong()).isEqualTo(pid);
        assertThat(pub.get("siguiendo").asBoolean()).isTrue();
        assertThat(pub.get("esPropia").asBoolean()).isTrue();
        assertThat(pub.get("etiquetas").get(0).get("nombre").asText()).isEqualTo("Tarea");
        assertThat(pub.get("mensaje").get("texto").asText()).contains("plantas");
        assertThat(esperar(recibidos, "event").get("event").asText()).isEqualTo("publicacion.creada");

        // FTS en espanol ("planta" encuentra "plantas"), etiqueta y orden.
        assertThat(rows(get(base + "/publicaciones?q=planta", tLuis)).size()).isEqualTo(1);
        assertThat(rows(get(base + "/publicaciones?q=volcanes", tLuis)).size()).isZero();
        assertThat(rows(get(base + "/publicaciones?etiqueta=" + anuncio, tLuis)).size()).isZero();
        assertThat(rows(get(base + "/publicaciones?orden=TOP", tLuis)).get(0).get("totalCount").asInt()).isEqualTo(1);
        assertThat(get(base + "/publicaciones?orden=x", tLuis).statusCode()).isEqualTo(400);

        // Luis responde mencionando a Sofia: un solo aviso, FORO_MENCION.
        String pubPath = "/comunicaciones/foros/publicaciones/" + pid;
        JsonNode r1 = rows(post(pubPath + "/respuestas", tLuis,
                Map.of("TEXTO", "Mira el capitulo 3 <@" + sofi + ">"))).get(0);
        JsonNode n1 = JSON.valueToTree(rabbit.receiveAndConvert("prueba.foros", 5000));
        assertThat(n1.get("tipo").asText()).isEqualTo("FORO_MENCION");
        assertThat(n1.get("destinatarios").get(0).asText()).isEqualTo("sofi.foro@colegio.edu.co");
        assertThat(n1.get("deepLink").asText())
                .startsWith("/app/comunicaciones/foros?foro=" + foro + "&publicacion=" + pid);

        // Ana sigue la publicacion: la siguiente respuesta (hilada) avisa a Ana y a Sofia.
        assertThat(rows(patch(pubPath + "/seguir", tAna, Map.of("SEGUIR", "S"))).get(0).get("siguiendo").asBoolean())
                .isTrue();
        JsonNode r2 = rows(post(pubPath + "/respuestas", tLuis,
                Map.of("TEXTO", "Y tambien el 4", "FK_MENSAJE_RESPUESTA", r1.get("id").asLong()))).get(0);
        assertThat(r2.get("respuestaA").get("id").asLong()).isEqualTo(r1.get("id").asLong());
        JsonNode n2 = JSON.valueToTree(rabbit.receiveAndConvert("prueba.foros", 5000));
        assertThat(n2.get("tipo").asText()).isEqualTo("FORO_RESPUESTA");
        List<String> dest = new java.util.ArrayList<>();
        n2.get("destinatarios").forEach(d -> dest.add(d.asText()));
        assertThat(dest).containsExactlyInAnyOrder("ana.foro@colegio.edu.co", "sofi.foro@colegio.edu.co");
        assertThat(rows(get(pubPath + "/respuestas", tSofi)).size()).isEqualTo(2);

        // Reacciones del chat sobre el cuerpo; el cuerpo no se borra desde el chat.
        long raiz = pub.get("mensaje").get("id").asLong();
        assertThat(rows(post("/comunicaciones/mensajes/" + raiz + "/reacciones", tLuis, Map.of("EMOJI", "ok")))
                .get(0).get("reacciones").get(0).get("total").asInt()).isEqualTo(1);
        assertThat(rows(get(pubPath, tSofi)).get(0).get("reacciones").asInt()).isEqualTo(1);
        assertThat(patch("/comunicaciones/mensajes/" + raiz + "/eliminar", tSofi, Map.of()).statusCode())
                .isEqualTo(400);

        // Moderacion: fijar y cerrar; cerrada solo responde la moderacion.
        assertThat(patch(pubPath + "/fijar", tLuis, Map.of("FIJADA", "S")).statusCode()).isEqualTo(403);
        assertThat(rows(patch(pubPath + "/fijar", tAna, Map.of("FIJADA", "S"))).get(0).get("fijada").asBoolean())
                .isTrue();
        assertThat(rows(patch(pubPath + "/cerrar", tAna, Map.of("CERRADA", "S"))).get(0).get("cerrada").asBoolean())
                .isTrue();
        assertThat(post(pubPath + "/respuestas", tSofi, Map.of("TEXTO", "gracias")).statusCode()).isEqualTo(409);
        rows(post(pubPath + "/respuestas", tAna, Map.of("TEXTO", "Cierro: quedo resuelto")));

        // Preguntas y respuestas: la autora marca la respuesta que la resolvio; otra persona no.
        assertThat(patch(pubPath + "/resolver", tLuis, Map.of("RESUELTA", "S")).statusCode()).isEqualTo(403);
        JsonNode resuelta = rows(patch(pubPath + "/resolver", tSofi,
                Map.of("RESUELTA", "S", "FK_MENSAJE_SOLUCION", r1.get("id").asLong()))).get(0);
        assertThat(resuelta.get("resuelta").asBoolean()).isTrue();
        assertThat(resuelta.get("solucionId").asLong()).isEqualTo(r1.get("id").asLong());

        // Mover etiqueta y borrar la respuesta de otra persona: moderacion.
        assertThat(rows(patch(pubPath + "/etiquetas", tAna, Map.of("ETIQUETAS", List.of(anuncio)))).get(0)
                .get("etiquetas").get(0).get("nombre").asText()).isEqualTo("Anuncio");
        assertThat(patch("/comunicaciones/foros/respuestas/" + r2.get("id").asLong() + "/eliminar", tSofi, Map.of())
                .statusCode()).isEqualTo(403);
        rows(patch("/comunicaciones/foros/respuestas/" + r1.get("id").asLong() + "/eliminar", tAna, Map.of()));
        JsonNode trasBorrar = rows(get(pubPath, tSofi)).get(0);
        assertThat(trasBorrar.get("respuestas").asInt()).isEqualTo(2);
        assertThat(trasBorrar.get("solucionId").isNull()).isTrue();

        assertThat(patch(pubPath + "/eliminar", tLuis, Map.of()).statusCode()).isEqualTo(403);
        rows(patch(pubPath + "/eliminar", tAna, Map.of()));
        assertThat(rows(get(base + "/publicaciones", tSofi)).size()).isZero();
        assertThat(get(pubPath, tSofi).statusCode()).isEqualTo(404);
        // Sin eventos pendientes: la reaccion de arriba no debe llegarle a otro test por el outbox.
        org.awaitility.Awaitility.await().atMost(10, TimeUnit.SECONDS).until(() -> jdbc.sql(
                "SELECT COUNT(*) FROM comunicaciones.toutbox_evento WHERE publicado_en IS NULL")
                .query(Long.class).single() == 0);
        if (admin.getQueueProperties("prueba.eventos") != null) admin.purgeQueue("prueba.eventos", false);
        ws.close();
    }

    @Test
    void buscarPersonasPorAlcanceSinTildesYPorDocumento() throws Exception {
        long rector = usuario(jdbc, "rector@a.edu.co", "Rector Dos Colegios", "CEVAL-DOCENTE");
        long natalia = usuario(jdbc, "natalia@b.edu.co", "Natalia Carpintero", "CEVAL-DOCENTE");
        long otro = usuario(jdbc, "otro@c.edu.co", "Ramón Ajeno", "CEVAL-DOCENTE");
        long root = usuario(jdbc, "root@sed.gov.co", "Super", "CEVAL-SUPER_ADMINISTRADOR");
        // El rector trabaja en los colegios 10 y 20; Natalia en el 20; Ramon en el 30.
        for (var f : List.of(List.of("rector@a.edu.co", "1", "10"), List.of("rector@a.edu.co", "1", "20"),
                List.of("natalia@b.edu.co", "555123", "20"), List.of("otro@c.edu.co", "9", "30"))) {
            long tu = jdbc.sql("""
                    INSERT INTO academico_test.tusuario (cuenta, identificacion, primer_nombre, primer_apellido)
                    VALUES (:c, :d, 'X', 'Y') ON CONFLICT DO NOTHING RETURNING pk_tusuario""")
                    .param("c", f.get(0)).param("d", f.get(1)).query(Long.class).optional()
                    .orElseGet(() -> jdbc.sql("SELECT pk_tusuario FROM academico_test.tusuario WHERE cuenta = :c")
                            .param("c", f.get(0)).query(Long.class).single());
            long sede = jdbc.sql("INSERT INTO academico_test.tsede (fk_testablecimiento) VALUES (:e) RETURNING pk_tsede")
                    .param("e", Long.parseLong(f.get(2))).query(Long.class).single();
            jdbc.sql("INSERT INTO academico_test.tsede_usuario (fk_tsede, fk_tusuario) VALUES (:s, :t)")
                    .param("s", sede).param("t", tu).update();
        }
        String tRector = JWT.issueAccessToken("rector@a.edu.co", rector, null, Set.of("CEVAL-DOCENTE"), null, "rect");
        String tRoot = JWT.issueAccessToken("root@sed.gov.co", root, null,
                Set.of("CEVAL-SUPER_ADMINISTRADOR"), null, "root");

        // Multi-colegio: encuentra por correo, sin tildes ni mayusculas, y por documento.
        assertThat(rows(get("/comunicaciones/personas?q=NATALIA%40B.EDU", tRector)).findValuesAsText("id"))
                .containsExactly(String.valueOf(natalia));
        assertThat(rows(get("/comunicaciones/personas?q=555123", tRector)).findValuesAsText("id"))
                .containsExactly(String.valueOf(natalia));
        assertThat(rows(get("/comunicaciones/personas?q=ramon", tRector))).isEmpty();
        // Super administrador: todos los colegios, con paginacion.
        assertThat(rows(get("/comunicaciones/personas?q=ram%C3%B3n", tRoot)).findValuesAsText("id"))
                .containsExactly(String.valueOf(otro));
        assertThat(rows(get("/comunicaciones/personas?limite=1", tRoot))).hasSize(1);
        assertThat(rows(get("/comunicaciones/personas?limite=1&desde=1", tRoot)).get(0).get("id").asLong())
                .isNotEqualTo(rows(get("/comunicaciones/personas?limite=1", tRoot)).get(0).get("id").asLong());
    }

    @Test
    void adjuntosBorradoresDuplicarYVotacionRapida() throws Exception {
        String tAna = token("ana@colegio.edu.co", ana, "CEVAL-DOCENTE");
        String tSofi = token("sofi@colegio.edu.co", sofi, "CEVAL-ESTUDIANTE");
        JsonNode canal = rows(post("/comunicaciones/conversaciones", tAna,
                Map.of("NOMBRE", "Extras " + System.nanoTime(), "CATEGORIA", "VOTACION", "MIEMBROS", List.of(sofi)))).get(0);
        long id = canal.get("id").asLong();
        String base = "/comunicaciones/conversaciones/" + id;
        assertThat(canal.get("actividadAbierta").asBoolean()).isTrue();
        assertThat(canal.get("esBot").asBoolean()).isFalse();

        // Adjunto: el pk que reenvia file-service; nombre y formato salen de TARCHIVO.
        jdbc.sql("INSERT INTO academico_test.tarchivo (pk_tarchivo, nombre, peso, created_by) VALUES "
                + "(9001, 'acta.pdf', 2048, 'ana@colegio.edu.co'), (9002, 'virus.exe', 10, 'ana@colegio.edu.co'), "
                + "(9003, 'ajeno.pdf', 10, 'sofi@colegio.edu.co')").update();
        JsonNode conAdjunto = rows(post(base + "/mensajes", tAna, Map.of("TEXTO", "", "ADJUNTO", "9001"))).get(0);
        assertThat(conAdjunto.get("adjunto").get("archivoId").asLong()).isEqualTo(9001);
        assertThat(conAdjunto.get("adjunto").get("formato").asText()).isEqualTo("PDF");
        assertThat(post(base + "/mensajes", tAna, Map.of("ADJUNTO", 9001)).statusCode()).isEqualTo(409);
        assertThat(post(base + "/mensajes", tAna, Map.of("ADJUNTO", 9002)).statusCode()).isEqualTo(400);
        assertThat(post(base + "/mensajes", tAna, Map.of("ADJUNTO", 9003)).statusCode()).isEqualTo(403);
        JsonNode archivos = rows(get("/comunicaciones/archivos", tSofi));
        assertThat(archivos.get(0).get("id").asLong()).isEqualTo(9001);
        assertThat(archivos.get(0).get("esPropio").asBoolean()).isFalse();
        assertThat(patch("/comunicaciones/archivos/9001/eliminar", tSofi, Map.of()).statusCode()).isEqualTo(403);
        rows(patch("/comunicaciones/archivos/9001/eliminar", tAna, Map.of()));
        assertThat(rows(get("/comunicaciones/archivos", tSofi)).size()).isZero();
        assertThat(get("/comunicaciones/archivos/9001/contenido", tAna).statusCode()).isEqualTo(404);

        // Borrador: uno por canal; al enviar pasa a ENVIADO.
        JsonNode b = rows(send("PUT", base + "/borrador", tAna, Map.of("TEXTO", "a medias"))).get(0);
        long idB = rows(send("PUT", base + "/borrador", tAna, Map.of("TEXTO", "a medias 2"))).get(0).get("id").asLong();
        assertThat(idB).isEqualTo(b.get("id").asLong());
        assertThat(rows(get("/comunicaciones/borradores", tAna)).get(0).get("texto").asText()).isEqualTo("a medias 2");
        assertThat(patch("/comunicaciones/borradores/" + idB + "/enviar", tSofi, Map.of()).statusCode()).isEqualTo(404);
        JsonNode enviado = rows(patch("/comunicaciones/borradores/" + idB + "/enviar", tAna, Map.of())).get(0);
        assertThat(enviado.get("estado").asText()).isEqualTo("ENVIADO");
        assertThat(rows(send("PUT", base + "/borrador", tAna, Map.of("TEXTO", "  "))).size()).isZero();
        long otro = rows(send("PUT", base + "/borrador", tAna, Map.of("TEXTO", "otro"))).get(0).get("id").asLong();
        rows(patch("/comunicaciones/borradores/" + otro + "/eliminar", tAna, Map.of()));
        assertThat(rows(get("/comunicaciones/borradores", tAna)).size()).isEqualTo(1);

        // Votacion rapida: solo quien administra la crea; un voto por persona.
        var votacion = Map.of("PREGUNTA", "¿Salida el viernes?", "TIPO", "SI_NO", "MINUTOS", 5);
        assertThat(post(base + "/votaciones-rapidas", tSofi, votacion).statusCode()).isEqualTo(403);
        JsonNode v = rows(post(base + "/votaciones-rapidas", tAna, votacion)).get(0);
        long idV = v.get("id").asLong();
        assertThat(v.get("votacion").get("opciones").get(0).get("etiqueta").asText()).isEqualTo("Sí");
        JsonNode votado = rows(post("/comunicaciones/mensajes/" + idV + "/votacion/votar", tSofi,
                Map.of("FK_OPCION", 2))).get(0).get("votacion");
        assertThat(votado.get("miVoto").asInt()).isEqualTo(2);
        assertThat(votado.get("opciones").get(1).get("votos").asInt()).isEqualTo(1);
        assertThat(post("/comunicaciones/mensajes/" + idV + "/votacion/votar", tSofi, Map.of("FK_OPCION", 1))
                .statusCode()).isEqualTo(409);
        JsonNode editada = rows(patch("/comunicaciones/mensajes/" + idV + "/votacion", tAna,
                Map.of("PREGUNTA", "¿Salida el sabado?", "TIPO", "VERDADERO_FALSO", "MINUTOS", 1))).get(0);
        assertThat(editada.get("votacion").get("opciones").get(1).get("votos").asInt()).isZero();
        jdbc.sql("UPDATE comunicaciones.tvotacion_rapida SET cierra_en = NOW() - INTERVAL '1 minute' WHERE fk_tmensaje = :m")
                .param("m", idV).update();
        assertThat(post("/comunicaciones/mensajes/" + idV + "/votacion/votar", tSofi, Map.of("FK_OPCION", 1))
                .statusCode()).isEqualTo(409);

        // Duplicar: copia con los mismos miembros, administrada por quien la pide.
        assertThat(post(base + "/duplicar", tSofi, Map.of()).statusCode()).isEqualTo(403);
        JsonNode copia = rows(post(base + "/duplicar", tAna, Map.of())).get(0);
        assertThat(copia.get("nombre").asText()).isEqualTo(canal.get("nombre").asText() + " (copia)");
        assertThat(copia.get("totalMiembros").asInt()).isEqualTo(2);
        assertThat(rows(post(base + "/duplicar", tAna, Map.of())).get(0).get("nombre").asText())
                .endsWith("(copia 2)");
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
