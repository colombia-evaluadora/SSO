package com.co.eurekatic.comms;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.amqp.rabbit.core.RabbitAdmin;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
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
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Contrato REST de comunicados, encuestas, elecciones y evaluaciones (mocks
 * del front) contra Postgres con V560/V561/V580 y un modelo academico minimo.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "comms.jwt.secret=" + ActividadesIntegrationTest.SECRETO, "eureka.client.enabled=false",
        "comms.outbox.intervalo-ms=200"})
@Testcontainers
class ActividadesIntegrationTest {

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

    static long rector;
    static long docente;
    static long sofi;
    static long pepe;
    static long mama;
    static String tRector;
    static String tDocente;
    static String tSofi;
    static String tPepe;
    static String tMama;

    @BeforeAll
    static void esquema() throws Exception {
        var ds = new org.springframework.jdbc.datasource.DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        var j = JdbcClient.create(ds);
        try (var c = ds.getConnection(); var st = c.createStatement()) {
            st.execute(new String(ActividadesIntegrationTest.class.getResourceAsStream("/esquema-base.sql").readAllBytes()));
            st.execute(new String(ActividadesIntegrationTest.class.getResourceAsStream("/esquema-academico.sql").readAllBytes()));
            for (String m : List.of("V560__comunicaciones_chat_ddl.sql", "V561__comunicaciones_outbox_eventos.sql",
                    "V561.1__comunicaciones_outbox_registrar.sql", "V575__comunicaciones_chat_borradores_votaciones_ddl.sql",
                    "V580__comunicaciones_actividades_ddl.sql",
                    "V580__comunicaciones_actividades_ddl.sql")) {
                st.execute(Files.readString(Path.of("../postgres/migrations/" + m)));
            }
        }
        rector = usuario(j, "rector@colegio.edu.co", "Rita Rector", "CEVAL-RECTOR");
        long tuRector = tusuario(j, "rector@colegio.edu.co", null, "Rita", "Rector");
        long fRector = j.sql("INSERT INTO academico_test.TFUNCIONARIO (FK_TUSUARIO) VALUES (:t) RETURNING PK_TFUNCIONARIO")
                .param("t", tuRector).query(Long.class).single();
        j.sql("UPDATE academico_test.TESTABLECIMIENTO SET FK_TFUNCIONARIO_RECTOR = :f").param("f", fRector).update();

        docente = usuario(j, "docente@colegio.edu.co", "Diego Docente", "CEVAL-DOCENTE");
        long tuDoc = tusuario(j, "docente@colegio.edu.co", null, "Diego", "Docente");
        j.sql("INSERT INTO academico_test.TSEDE_USUARIO (FK_TSEDE, FK_TROL, FK_TUSUARIO) VALUES (200, 10, :t)")
                .param("t", tuDoc).update();

        mama = usuario(j, "mama@correo.com", "Marta Madre", "CEVAL-ACUDIENTE");
        long tuMama = tusuario(j, "mama@correo.com", null, "Marta", "Madre");
        long padre = j.sql("INSERT INTO academico_test.TPADRE (FK_TUSUARIO) VALUES (:t) RETURNING PK_TPADRE")
                .param("t", tuMama).query(Long.class).single();

        sofi = estudiante(j, "sofi@colegio.edu.co", "Sofia Gil", "1001", padre);
        pepe = estudiante(j, "pepe@colegio.edu.co", "Pepe Paz", "1002", null);

        tRector = token("rector@colegio.edu.co", rector, "CEVAL-RECTOR");
        tDocente = token("docente@colegio.edu.co", docente, "CEVAL-DOCENTE");
        tSofi = token("sofi@colegio.edu.co", sofi, "CEVAL-ESTUDIANTE");
        tPepe = token("pepe@colegio.edu.co", pepe, "CEVAL-ESTUDIANTE");
        tMama = token("mama@correo.com", mama, "CEVAL-ACUDIENTE");
    }

    private static long usuario(JdbcClient j, String email, String nombre, String rol) {
        long id = j.sql("INSERT INTO users (username, full_name, email) VALUES (:e, :n, :e) RETURNING id_user")
                .param("e", email).param("n", nombre).query(Long.class).single();
        j.sql("INSERT INTO role (name) VALUES (:r) ON CONFLICT DO NOTHING").param("r", rol).update();
        j.sql("INSERT INTO role_users SELECT :u, id_role FROM role WHERE name = :r").param("u", id).param("r", rol).update();
        return id;
    }

    private static long tusuario(JdbcClient j, String cuenta, String correo, String nombre, String apellido) {
        return j.sql("""
                INSERT INTO academico_test.TUSUARIO (CUENTA, CORREO_ELECTRONICO, PRIMER_NOMBRE, PRIMER_APELLIDO,
                    IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO)
                VALUES (:c, :m, :n, :a, left(:c, 20), 2) RETURNING PK_TUSUARIO""")
                .param("c", cuenta).param("m", correo).param("n", nombre).param("a", apellido)
                .query(Long.class).single();
    }

    private static long estudiante(JdbcClient j, String email, String nombre, String doc, Long padre) {
        long id = usuario(j, email, nombre, "CEVAL-ESTUDIANTE");
        String[] partes = nombre.split(" ");
        long tu = tusuario(j, doc, email, partes[0], partes[1]);
        long es = j.sql("INSERT INTO academico_test.TESTUDIANTE (FK_TUSUARIO) VALUES (:t) RETURNING PK_TESTUDIANTE")
                .param("t", tu).query(Long.class).single();
        j.sql("INSERT INTO academico_test.TMATRICULA (FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_MATRICULA, FK_TPADRE) VALUES (:e, 500, 1, :p)")
                .param("e", es).param("p", padre).update();
        return id;
    }

    private static String token(String email, long id, String rol) {
        return JWT.issueAccessToken(email, id, null, Set.of(rol), "COLEGIO DEMO", email.substring(0, 4));
    }

    @BeforeEach
    void cola() {
        var admin = new RabbitAdmin(rabbit.getConnectionFactory());
        admin.declareExchange(new TopicExchange("notifications", true, false));
        Queue cola = QueueBuilder.nonDurable("prueba.actividades").build();
        admin.declareQueue(cola);
        admin.declareBinding(BindingBuilder.bind(cola).to(new TopicExchange("notifications", true, false)).with("evento"));
        admin.purgeQueue("prueba.actividades", false);
    }

    /** Espera un evento del tipo dado y devuelve sus destinatarios. */
    private List<String> evento(String tipo) {
        long fin = System.currentTimeMillis() + 8000;
        while (System.currentTimeMillis() < fin) {
            Object m = rabbit.receiveAndConvert("prueba.actividades", 500);
            if (m == null) continue;
            JsonNode n = JSON.valueToTree(m);
            if (tipo.equals(n.get("tipo").asText())) {
                List<String> out = new ArrayList<>();
                n.get("destinatarios").forEach(d -> out.add(d.asText()));
                return out;
            }
        }
        throw new AssertionError("No llego " + tipo);
    }

    @Test
    void comunicadoPorAudienciaConLecturaYAviso() throws Exception {
        Map<String, Object> body = Map.of("TITULO", "Suspension de clases", "DESCRIPCION", "Importante",
                "AUDIENCIA", List.of("ESTUDIANTES", "PADRES"), "PUBLICAR_EN", Instant.now().toString(),
                "CONTENIDO_HTML", "<p>Hola <strong>familias</strong></p><script>alert(1)</script>");
        assertThat(post("/comunicaciones/comunicados", tDocente, body).statusCode()).isEqualTo(403);
        JsonNode canal = rows(post("/comunicaciones/comunicados", tRector, body)).get(0);
        long id = canal.get("id").asLong();
        assertThat(canal.get("categoria").asText()).isEqualTo("ANUNCIO");
        assertThat(canal.get("totalMiembros").asInt()).isEqualTo(4);
        assertThat(evento("CHAT_COMUNICADO")).containsExactlyInAnyOrder(
                "sofi@colegio.edu.co", "pepe@colegio.edu.co", "mama@correo.com");

        JsonNode visto = rows(get("/comunicaciones/conversaciones/" + id + "/comunicado", tSofi)).get(0);
        assertThat(visto.get("contenidoHtml").asText()).contains("<strong>familias</strong>").doesNotContain("script");
        assertThat(visto.get("esCreador").asBoolean()).isFalse();
        assertThat(visto.get("leidos").isNull()).isTrue();
        assertThat(get("/comunicaciones/conversaciones/" + id + "/comunicado", tDocente).statusCode()).isEqualTo(404);
        // El estudiante solo lee; el acudiente puede comentar.
        assertThat(post("/comunicaciones/conversaciones/" + id + "/mensajes", tSofi, Map.of("TEXTO", "hola"))
                .statusCode()).isEqualTo(403);
        // Mensaje de apertura fijado.
        JsonNode mensajes = rows(get("/comunicaciones/conversaciones/" + id + "/mensajes", tSofi));
        assertThat(mensajes.get(0).get("fijado").asBoolean()).isTrue();

        JsonNode antes = rows(get("/comunicaciones/conversaciones/" + id + "/comunicado", tRector)).get(0);
        assertThat(antes.get("leidos").asInt()).isZero();
        assertThat(antes.get("totalDestinatarios").asInt()).isEqualTo(3);
        rows(patch("/comunicaciones/conversaciones/" + id + "/leido", tSofi, Map.of()));
        assertThat(rows(get("/comunicaciones/conversaciones/" + id + "/comunicado", tRector)).get(0)
                .get("leidos").asInt()).isEqualTo(1);

        // Programado: sin aviso ni contenido para la audiencia hasta la hora.
        var prog = new HashMap<>(body);
        prog.put("TITULO", "Reunion de padres");
        prog.put("PUBLICAR_EN", Instant.now().plus(1, ChronoUnit.DAYS).toString());
        long id2 = rows(post("/comunicaciones/comunicados", tRector, prog)).get(0).get("id").asLong();
        assertThat(rows(get("/comunicaciones/conversaciones/" + id2 + "/comunicado", tMama)).get(0)
                .get("contenidoHtml").asText()).isEmpty();
        assertThat(jdbc.sql("SELECT notificado_en IS NULL FROM comunicaciones.tcomunicado WHERE fk_tcanal = :c")
                .param("c", id2).query(Boolean.class).single()).isTrue();
    }

    @Test
    void eleccionConCensoVotoUnicoYSecreto() throws Exception {
        JsonNode opciones = rows(get("/comunicaciones/votantes/opciones", tRector)).get(0);
        assertThat(opciones.get("grados").get(0).asText()).isEqualTo("Sexto A");
        assertThat(opciones.get("funcionarios").toString()).contains("Docente", "Rector");
        JsonNode votantes = rows(post("/comunicaciones/votantes/query", tRector,
                Map.of("GRUPO", "GRADO", "VALOR", "Sexto A")));
        assertThat(votantes.size()).isEqualTo(2);
        assertThat(votantes.get(0).get("documento").asText()).startsWith("TI ");

        Map<String, Object> body = new HashMap<>(Map.of("NOMBRE", "Personero 2027", "DESCRIPCION", "",
                "FK_JORNADA", 3, "VER_RESULTADOS", "N", "VOTANTES", List.of(sofi, pepe),
                "CANDIDATOS", List.of(Map.of("NOMBRE", "Ana", "NUMERO", "1", "LEMA", "Si se puede"),
                        Map.of("NOMBRE", "Beto", "NUMERO", "2", "LEMA", "Juntos"))));
        assertThat(post("/comunicaciones/elecciones", tDocente, body).statusCode()).isEqualTo(403);
        assertThat(post("/comunicaciones/elecciones", tRector, Map.of("NOMBRE", "x", "FK_JORNADA", 3,
                "CANDIDATOS", List.of())).statusCode()).isEqualTo(400);
        JsonNode canal = rows(post("/comunicaciones/elecciones", tRector, body)).get(0);
        long id = canal.get("id").asLong();
        assertThat(canal.get("actividadAbierta").asBoolean()).isTrue();
        assertThat(evento("CHAT_ELECCION")).containsExactlyInAnyOrder("sofi@colegio.edu.co", "pepe@colegio.edu.co");

        JsonNode e = rows(get("/comunicaciones/conversaciones/" + id + "/eleccion", tSofi)).get(0);
        long candidato = e.get("candidatos").get(0).get("id").asLong();
        assertThat(e.get("totalHabilitados").asInt()).isEqualTo(2);
        assertThat(post("/comunicaciones/conversaciones/" + id + "/mensajes", tSofi, Map.of("TEXTO", "x"))
                .statusCode()).isEqualTo(403);

        JsonNode votado = rows(post("/comunicaciones/conversaciones/" + id + "/eleccion/votar", tSofi,
                Map.of("FK_CANDIDATO", candidato))).get(0);
        assertThat(votado.get("yaVoto").asBoolean()).isTrue();
        // Sin resultados en vivo: el votante no ve conteos; el creador si.
        assertThat(votado.get("candidatos").get(0).get("votos").asInt()).isZero();
        assertThat(rows(get("/comunicaciones/conversaciones/" + id + "/eleccion", tRector)).get(0)
                .get("candidatos").get(0).get("votos").asInt()).isEqualTo(1);
        assertThat(post("/comunicaciones/conversaciones/" + id + "/eleccion/votar", tSofi,
                Map.of("FK_CANDIDATO", candidato)).statusCode()).isEqualTo(409);
        assertThat(post("/comunicaciones/conversaciones/" + id + "/eleccion/votar", tDocente,
                Map.of("FK_CANDIDATO", candidato)).statusCode()).isEqualTo(404);
        // La urna no guarda quien voto.
        assertThat(jdbc.sql("""
                SELECT COUNT(*) FROM information_schema.columns
                 WHERE table_schema = 'comunicaciones' AND table_name = 'televeccion_voto' AND column_name LIKE '%usuario%'""")
                .query(Integer.class).single()).isZero();

        assertThat(patch("/comunicaciones/conversaciones/" + id + "/eleccion/cerrar", tSofi, Map.of()).statusCode())
                .isEqualTo(403);
        JsonNode cerrado = rows(patch("/comunicaciones/conversaciones/" + id + "/eleccion/cerrar", tRector, Map.of())).get(0);
        assertThat(cerrado.get("actividadAbierta").asBoolean()).isFalse();
        assertThat(post("/comunicaciones/conversaciones/" + id + "/eleccion/votar", tPepe,
                Map.of("FK_CANDIDATO", candidato)).statusCode()).isEqualTo(409);
        JsonNode final_ = rows(get("/comunicaciones/conversaciones/" + id + "/eleccion", tPepe)).get(0);
        assertThat(final_.get("cerradaManualmente").asBoolean()).isTrue();
        assertThat(final_.get("candidatos").get(0).get("votos").asInt()).isEqualTo(1);
    }

    @Test
    void encuestaAnonimaDeUnaSolaRespuesta() throws Exception {
        Map<String, Object> body = Map.of("NOMBRE", "Satisfaccion", "DESCRIPCION", "", "RESULTADOS", "PUBLICOS",
                "PARTICIPANTES", List.of(sofi, pepe, mama),
                "PREGUNTAS", List.of(
                        Map.of("ORDEN", 1, "TIPO", "UNICA", "TEXTO", "Como vas", "OPCIONES", List.of("Bien", "Mal")),
                        Map.of("ORDEN", 2, "TIPO", "SI_NO", "TEXTO", "Repetirias", "OPCIONES", List.of()),
                        Map.of("ORDEN", 3, "TIPO", "REDACCION", "TEXTO", "Propuesta", "OPCIONES", List.of())));
        assertThat(post("/comunicaciones/encuestas", tSofi, body).statusCode()).isEqualTo(403);
        long id = rows(post("/comunicaciones/encuestas", tDocente, body)).get(0).get("id").asLong();
        assertThat(evento("CHAT_ENCUESTA")).hasSize(3);

        JsonNode e = rows(get("/comunicaciones/conversaciones/" + id + "/encuesta", tSofi)).get(0);
        assertThat(e.get("totalHabilitados").asInt()).isEqualTo(3);
        assertThat(e.get("preguntas").get(1).get("opciones").get(0).get("texto").asText()).isEqualTo("Sí");
        long p1 = e.get("preguntas").get(0).get("id").asLong();
        long o1 = e.get("preguntas").get(0).get("opciones").get(0).get("id").asLong();
        long p3 = e.get("preguntas").get(2).get("id").asLong();
        var resp = Map.of("RESPUESTAS", List.of(
                Map.of("FK_PREGUNTA", p1, "OPCIONES", List.of(o1)),
                Map.of("FK_PREGUNTA", p3, "OPCIONES", List.of(), "TEXTO", "Mas deporte")));
        JsonNode r = rows(post("/comunicaciones/conversaciones/" + id + "/encuesta/respuestas", tSofi, resp)).get(0);
        assertThat(r.get("yaRespondi").asBoolean()).isTrue();
        assertThat(r.get("participantes").asInt()).isEqualTo(1);
        assertThat(r.get("preguntas").get(0).get("opciones").get(0).get("votos").asInt()).isEqualTo(1);
        assertThat(r.get("preguntas").get(2).get("respuestas").get(0).asText()).isEqualTo("Mas deporte");
        assertThat(post("/comunicaciones/conversaciones/" + id + "/encuesta/respuestas", tSofi, resp).statusCode())
                .isEqualTo(409);
        assertThat(get("/comunicaciones/conversaciones/" + id + "/encuesta", tRector).statusCode()).isEqualTo(404);
    }

    @Test
    void evaluacionConCalificacionManual() throws Exception {
        Map<String, Object> body = new HashMap<>(Map.of("NOMBRE", "Examen fracciones", "DESCRIPCION", "",
                "PUNTAJE_TOTAL", 100, "MOSTRAR_RESULTADOS", "INMEDIATO", "PARTICIPANTES", List.of(sofi),
                "PREGUNTAS", List.of(
                        Map.of("ORDEN", 1, "TIPO", "UNICA", "TEXTO", "1/2 + 1/2", "PUNTOS", 60,
                                "OPCIONES", List.of(Map.of("TEXTO", "1", "CORRECTA", "S"), Map.of("TEXTO", "2", "CORRECTA", "N"))),
                        Map.of("ORDEN", 2, "TIPO", "REDACCION", "TEXTO", "Explica", "PUNTOS", 40, "OPCIONES", List.of()))));
        body.put("PUNTAJE_TOTAL", 90);
        assertThat(post("/comunicaciones/evaluaciones", tDocente, body).statusCode()).isEqualTo(400);
        body.put("PUNTAJE_TOTAL", 100);
        body.put("INTENTOS", 1);
        long id = rows(post("/comunicaciones/evaluaciones", tDocente, body)).get(0).get("id").asLong();
        assertThat(evento("CHAT_EVALUACION")).containsExactly("sofi@colegio.edu.co");

        JsonNode e = rows(get("/comunicaciones/conversaciones/" + id + "/evaluacion", tSofi)).get(0);
        assertThat(e.toString()).doesNotContain("\"correcta\":true");
        assertThat(get("/comunicaciones/conversaciones/" + id + "/evaluacion/entregas", tSofi).statusCode()).isEqualTo(403);
        long p1 = e.get("preguntas").get(0).get("id").asLong();
        long o1 = e.get("preguntas").get(0).get("opciones").get(0).get("id").asLong();
        long p2 = e.get("preguntas").get(1).get("id").asLong();
        var resp = Map.of("RESPUESTAS", List.of(Map.of("FK_PREGUNTA", p1, "OPCIONES", List.of(o1)),
                Map.of("FK_PREGUNTA", p2, "OPCIONES", List.of(), "TEXTO", "Se suman")));
        JsonNode mia = rows(post("/comunicaciones/conversaciones/" + id + "/evaluacion/entregas", tSofi, resp)).get(0);
        assertThat(mia.get("intentosUsados").asInt()).isEqualTo(1);
        assertThat(mia.get("miNota").asDouble()).isEqualTo(60.0);
        assertThat(mia.get("miNotaPendiente").asBoolean()).isTrue();
        assertThat(post("/comunicaciones/conversaciones/" + id + "/evaluacion/entregas", tSofi, resp).statusCode())
                .isEqualTo(409);

        JsonNode entregas = rows(get("/comunicaciones/conversaciones/" + id + "/evaluacion/entregas", tDocente));
        long entrega = entregas.get(0).get("id").asLong();
        assertThat(entregas.get(0).get("estudiante").asText()).isEqualTo("Sofia Gil");
        assertThat(patch("/comunicaciones/evaluaciones/entregas/" + entrega, tDocente,
                Map.of("CALIFICACIONES", List.of(Map.of("FK_PREGUNTA", p2, "PUNTOS", 50)))).statusCode()).isEqualTo(400);
        JsonNode calificada = rows(patch("/comunicaciones/evaluaciones/entregas/" + entrega, tDocente,
                Map.of("CALIFICACIONES", List.of(Map.of("FK_PREGUNTA", p2, "PUNTOS", 30))))).get(0);
        assertThat(calificada.get("estado").asText()).isEqualTo("CALIFICADA");
        JsonNode despues = rows(get("/comunicaciones/conversaciones/" + id + "/evaluacion", tSofi)).get(0);
        assertThat(despues.get("miNota").asDouble()).isEqualTo(90.0);
        assertThat(despues.get("miNotaPendiente").asBoolean()).isFalse();
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
