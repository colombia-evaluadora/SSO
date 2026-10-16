package com.co.eurekatic.notificationservice.bandeja;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.notificationservice.AbstractIntegrationTest;
import com.co.eurekatic.notificationservice.push.WebPushCrypto;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.interfaces.ECPublicKey;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

/**
 * Contrato REST de la bandeja contra el que consume el front
 * ({@code src/features/notificaciones}) y entrada por la cola de eventos.
 */

class BandejaIntegrationTest extends AbstractIntegrationTest {

    /** El mismo que {@code notif.jwt.secret} de application-test.yml (un solo contexto para todos los IT). */
    static final String SECRETO = "secreto-de-pruebas-de-al-menos-32-bytes-para-hs256";
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newHttpClient();
    private static final JwtTokenService JWT = new JwtTokenService(new JwtProperties(
            null, "-", "sso-postgres", 3600, 3600, "Authorization", "Bearer ", SECRETO));

    @Value("${local.server.port}") int port;
    @Autowired RabbitTemplate rabbit;
    @Autowired JdbcClient jdbc;

    private final String ana = JWT.issueAccessToken("Ana@Colegio.edu.co", 1L, Set.of("CEVAL-DOCENTE"));
    private final String luis = JWT.issueAccessToken("luis@colegio.edu.co", 2L, Set.of("CEVAL-DOCENTE"));

    @BeforeEach
    void limpiar() {
        jdbc.sql("DELETE FROM notificacion").update();
        jdbc.sql("DELETE FROM notificacion_preferencia").update();
        jdbc.sql("DELETE FROM notificacion_horario_silencioso").update();
        jdbc.sql("DELETE FROM push_suscripcion").update();
    }

    @Test
    void eventoLlegaALaBandejaYSeMarcaLeida() throws Exception {
        publicar(evento("CHAT_MENCION", "k1", null, "Darlene"));
        await().atMost(10, TimeUnit.SECONDS).until(() -> contador(ana) == 1);
        assertThat(contador(luis)).isZero();

        JsonNode pagina = get("/notificaciones", ana).get("body");
        JsonNode item = pagina.get("items").get(0);
        assertThat(item.get("tipo").asText()).isEqualTo("CHAT_MENCION");
        assertThat(item.get("categoria").asText()).isEqualTo("CHAT");
        assertThat(item.get("deep_link").asText()).isEqualTo("/app/comunicaciones/chat?canal=1");
        assertThat(item.get("leida_en").isNull()).isTrue();
        assertThat(item.get("actores").get(0).asText()).isEqualTo("Darlene");
        assertThat(pagina.get("next_cursor").isNull()).isTrue();
        String id = item.get("id").asText();

        assertThat(send("PATCH", "/notificaciones/" + id + "/leida", luis, "{\"leida\":true}").statusCode()).isEqualTo(404);
        assertThat(send("PATCH", "/notificaciones/" + id + "/leida", ana, "{\"leida\":true}").statusCode()).isEqualTo(204);
        assertThat(contador(ana)).isZero();
        assertThat(get("/notificaciones?estado=leidas", ana).get("body").get("items")).hasSize(1);
        assertThat(get("/notificaciones?estado=no-leidas", ana).get("body").get("items")).isEmpty();

        assertThat(send("PATCH", "/notificaciones/" + id + "/archivar", ana, "{}").statusCode()).isEqualTo(204);
        assertThat(get("/notificaciones", ana).get("body").get("items")).isEmpty();
    }

    @Test
    void agrupaDeduplicaYPaginaPorCursor() throws Exception {
        publicar(evento("CHAT_REACCION", "r1", "msg:9", "Darlene"));
        await().atMost(10, TimeUnit.SECONDS).until(() -> contador(ana) == 1);
        publicar(evento("CHAT_REACCION", "r2", "msg:9", "Luis"));
        publicar(evento("CHAT_REACCION", "r2", "msg:9", "Luis")); // reintento del productor
        await().atMost(10, TimeUnit.SECONDS).until(() ->
                get("/notificaciones", ana).get("body").get("items").get(0).get("conteo").asInt() == 2);
        Thread.sleep(500);
        JsonNode item = get("/notificaciones", ana).get("body").get("items").get(0);
        assertThat(item.get("conteo").asInt()).isEqualTo(2);
        assertThat(item.get("actores").toString()).isEqualTo("[\"Luis\",\"Darlene\"]");

        publicar(evento("PLANEADOR_VALIDACION", "p1", null, null));
        publicar(evento("INFORMES_BOLETIN", "b1", null, null));
        await().atMost(10, TimeUnit.SECONDS).until(() -> contador(ana) == 3);
        JsonNode p1 = get("/notificaciones?limit=2", ana).get("body");
        assertThat(p1.get("items")).hasSize(2);
        String cursor = p1.get("next_cursor").asText();
        JsonNode p2 = get("/notificaciones?limit=2&cursor=" + java.net.URLEncoder.encode(cursor, "UTF-8"), ana).get("body");
        assertThat(p2.get("items")).hasSize(1);
        assertThat(p2.get("next_cursor").isNull()).isTrue();
        assertThat(get("/notificaciones?categoria=INFORMES", ana).get("body").get("items")).hasSize(1);

        assertThat(send("POST", "/notificaciones/leer-todas", ana, "{\"categoria\":\"CHAT\"}").statusCode()).isEqualTo(204);
        assertThat(contador(ana)).isEqualTo(2);
        assertThat(send("POST", "/notificaciones/leer-todas", ana, "{}").statusCode()).isEqualTo(204);
        assertThat(contador(ana)).isZero();
    }

    @Test
    void preferenciasMatrizResueltaYPisoInstitucional() throws Exception {
        JsonNode pref = get("/notificaciones/preferencias", ana).get("body");
        assertThat(pref.get("tipos").get(0).get("in_app").asBoolean()).isTrue();
        assertThat(pref.get("horario_silencioso").get("zona").asText()).isEqualTo("America/Bogota");

        String body = """
                {"tipos":[{"tipo":"CHAT_REACCION","push":true,"email":false}],
                 "horario_silencioso":{"activo":true,"desde":"22:00","hasta":"06:00","dias":[2,3,4,5,6]}}""";
        assertThat(send("PUT", "/notificaciones/preferencias", ana, body).statusCode()).isEqualTo(200);
        pref = get("/notificaciones/preferencias", ana).get("body");
        JsonNode reaccion = null;
        for (JsonNode t : pref.get("tipos")) if (t.get("tipo").asText().equals("CHAT_REACCION")) reaccion = t;
        assertThat(reaccion.get("push").asBoolean()).isTrue();
        assertThat(pref.get("horario_silencioso").get("activo").asBoolean()).isTrue();
        assertThat(pref.get("horario_silencioso").get("dias").toString()).isEqualTo("[2,3,4,5,6]");

        String bloqueado = "{\"tipos\":[{\"tipo\":\"SISTEMA_MANTENIMIENTO\",\"push\":false,\"email\":true}]}";
        var r = send("PUT", "/notificaciones/preferencias", ana, bloqueado);
        assertThat(r.statusCode()).isEqualTo(409);
        assertThat(JSON.readTree(r.body()).get("message").asText()).isNotBlank();

        String desconocido = "{\"tipos\":[{\"tipo\":\"NO_EXISTE\",\"push\":true,\"email\":true}]}";
        assertThat(send("PUT", "/notificaciones/preferencias", ana, desconocido).statusCode()).isEqualTo(400);
    }

    @Test
    void suscripcionesPushAltaReasignacionYBaja() throws Exception {
        var par = WebPushCrypto.generarPar();
        String p256dh = WebPushCrypto.b64(WebPushCrypto.uncompressed((ECPublicKey) par.getPublic()));
        String auth = WebPushCrypto.b64(new byte[16]);
        String endpoint = "https://push.example.com/send/abc";
        String alta = JSON.writeValueAsString(Map.of("endpoint", endpoint,
                "keys", Map.of("p256dh", p256dh, "auth", auth), "userAgent", "Firefox", "plataforma", "Escritorio"));

        var r = send("POST", "/notificaciones/push/suscripciones", ana, alta);
        assertThat(r.statusCode()).isEqualTo(201);
        assertThat(JSON.readTree(r.body()).get("endpoint").asText()).isEqualTo(endpoint);
        assertThat(get("/notificaciones/push/suscripciones", ana).get("body")).hasSize(1);

        // Mismo navegador, otro usuario: se reasigna (D-4.4).
        assertThat(send("POST", "/notificaciones/push/suscripciones", luis, alta).statusCode()).isEqualTo(201);
        assertThat(get("/notificaciones/push/suscripciones", ana).get("body")).isEmpty();
        assertThat(get("/notificaciones/push/suscripciones", luis).get("body")).hasSize(1);

        String interno = alta.replace("https://push.example.com", "http://query-service:8084");
        assertThat(send("POST", "/notificaciones/push/suscripciones", luis, interno).statusCode()).isEqualTo(400);

        assertThat(send("DELETE", "/notificaciones/push/suscripciones", luis,
                "{\"endpoint\":\"" + endpoint + "\"}").statusCode()).isEqualTo(204);
        assertThat(get("/notificaciones/push/suscripciones", luis).get("body")).isEmpty();
    }

    @Test
    void sinTokenEs401() throws Exception {
        var r = HTTP.send(HttpRequest.newBuilder(uri("/notificaciones/contador")).GET().build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(r.statusCode()).isEqualTo(401);
        assertThat(get("/notificaciones?cursor=basura", ana).get("status").asInt()).isEqualTo(400);
    }

    private EventoNotificacion evento(String tipo, String dedupe, String agrupacion, String actor) {
        return new EventoNotificacion(tipo, List.of("ana@colegio.edu.co"), "COLOMBIA-EVALUADORA",
                "Titulo " + tipo, "Cuerpo", "/app/comunicaciones/chat?canal=1", Map.of("canal", 1),
                dedupe, agrupacion, actor, null, null);
    }

    private void publicar(EventoNotificacion e) {
        rabbit.convertAndSend("notifications", "evento", e);
    }

    private long contador(String token) throws Exception {
        return get("/notificaciones/contador", token).get("body").get("no_leidas").asLong();
    }

    private JsonNode get(String path, String token) throws Exception {
        var r = send("GET", path, token, null);
        var out = JSON.createObjectNode();
        out.put("status", r.statusCode());
        out.set("body", r.body() == null || r.body().isBlank() ? null : JSON.readTree(r.body()));
        return out;
    }

    private HttpResponse<String> send(String method, String path, String token, String body) throws Exception {
        var b = HttpRequest.newBuilder(uri(path)).header("Authorization", "Bearer " + token)
                .header("Content-Type", "application/json")
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
        return HTTP.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    private URI uri(String path) {
        return URI.create("http://localhost:" + port + path);
    }
}
