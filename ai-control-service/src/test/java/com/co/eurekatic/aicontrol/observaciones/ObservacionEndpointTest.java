package com.co.eurekatic.aicontrol.observaciones;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.util.Base64;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Cableado de punta a punta sin gastar cuota: un HttpServer local hace de
 * NVIDIA ({@code /v1/chat/completions}) y de query-service. Comprueba lo que
 * el proveedor recibe de verdad (max_tokens, extra_body con booleanos, sin
 * el nombre del estudiante) y lo que se guarda.
 */
@SpringBootTest
class ObservacionEndpointTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final HttpServer SERVER;
    private static final KeyPair KEYS;
    private static final Map<String, String> RECIBIDO = new ConcurrentHashMap<>();
    private static volatile String estadoGuardado;

    static {
        try {
            KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
            g.initialize(2048);
            KEYS = g.generateKeyPair();
            SERVER = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            SERVER.createContext("/v1/chat/completions", ex -> {
                RECIBIDO.put("llm", leer(ex));
                String contenido = JSON.writeValueAsString(Map.of(
                        "introduccion", "[ESTUDIANTE] vivio un periodo de avances.",
                        "dimensiones", java.util.List.of(Map.of("nombre", "Comunicativa",
                                "descripcion", "Narra cuentos con secuencia.")),
                        "fortalezas", java.util.List.of("Curiosidad"),
                        "aspectosPorFortalecer", java.util.List.of(),
                        "recomendaciones", java.util.List.of("Leer en familia"),
                        "sintesis", "Felicitaciones a [ESTUDIANTE]."));
                responder(ex, JSON.writeValueAsString(Map.of(
                        "id", "cmpl-1", "object", "chat.completion", "created", 1,
                        "model", "moonshotai/kimi-k2.5",
                        "choices", java.util.List.of(Map.of("index", 0, "finish_reason", "stop",
                                "message", Map.of("role", "assistant", "content", contenido))),
                        "usage", Map.of("prompt_tokens", 120, "completion_tokens", 80, "total_tokens", 200))));
            });
            SERVER.createContext("/informes/observacion/fuentes", ex -> {
                RECIBIDO.put("fuentes", leer(ex));
                RECIBIDO.put("auth", ex.getRequestHeaders().getFirst("Authorization"));
                String estado = estadoGuardado == null ? "null" : "\"" + estadoGuardado + "\"";
                responder(ex, """
                        {"rows":[
                          {"fecha":"2026-08-31","actividad":"Cuento","asignatura":"Comunicativa",
                           "observacion":"Sofía narra el cuento","estudiante":"Sofía","estado_guardado":%s,"origen_guardado":null},
                          {"fecha":"2026-09-10","actividad":"Rondas","asignatura":null,
                           "observacion":"Participa con entusiasmo","estudiante":"Sofía","estado_guardado":%s,"origen_guardado":null}
                        ]}""".formatted(estado, estado));
            });
            SERVER.createContext("/informes/observacion/guardar", ex -> {
                RECIBIDO.put("guardar", leer(ex));
                responder(ex, "{\"rows\":[{\"pk_testudiante_periodo_observacion\":1}]}");
            });
            SERVER.start();
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        String base = "http://127.0.0.1:" + SERVER.getAddress().getPort();
        r.add("spring.ai.openai.base-url", () -> base + "/v1");
        r.add("spring.ai.openai.api-key", () -> "nvapi-test");
        r.add("sso.ai.query-service-base-url", () -> base);
        r.add("sso.ai.cache-ttl", () -> "0s");
        r.add("sso.jwt.public-key", () -> Base64.getEncoder().encodeToString(KEYS.getPublic().getEncoded()));
        r.add("eureka.client.enabled", () -> "false");
    }

    @AfterAll
    static void stop() {
        SERVER.stop(0);
    }

    @Autowired
    WebApplicationContext context;

    MockMvc mvc;
    String token;

    @BeforeEach
    void setUp() {
        mvc = MockMvcBuilders.webAppContextSetup(context).apply(springSecurity()).build();
        RECIBIDO.clear();
        estadoGuardado = null;
        String priv = Base64.getEncoder().encodeToString(KEYS.getPrivate().getEncoded());
        String pub = Base64.getEncoder().encodeToString(KEYS.getPublic().getEncoded());
        token = new JwtTokenService(JwtProperties.rsaOnly(priv, pub, "sso-postgres", 600, 600,
                "Authorization", "Bearer ")).issueAccessToken("docente@test", 7L, Set.of("CEVAL-DOCENTE"));
    }

    @Test
    void generaGuardaYNoLeMandaElNombreAlProveedor() throws Exception {
        mvc.perform(post("/ai/observaciones/periodo")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"FK_TMATRICULA\":990001,\"FK_TPERIODO_EVALUACION\":970001}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.estado").value("APROBADA"))
                .andExpect(jsonPath("$.origen").value(2))
                .andExpect(jsonPath("$.tokensEntrada").value(120))
                .andExpect(jsonPath("$.observacion").value(org.hamcrest.Matchers.startsWith("Sofía vivio")));

        assertThat(RECIBIDO.get("auth")).isEqualTo("Bearer " + token);

        JsonNode llm = JSON.readTree(RECIBIDO.get("llm"));
        assertThat(llm.path("model").asString()).isEqualTo("moonshotai/kimi-k2.5");
        assertThat(llm.path("max_tokens").asInt()).isEqualTo(1500);
        assertThat(llm.path("chat_template_kwargs").path("thinking").isBoolean()).isTrue();
        assertThat(llm.path("chat_template_kwargs").path("thinking").asBoolean()).isFalse();
        assertThat(RECIBIDO.get("llm")).doesNotContain("Sofía").contains("[ESTUDIANTE] narra el cuento");

        JsonNode guardar = JSON.readTree(RECIBIDO.get("guardar"));
        assertThat(guardar.path("FK_TMATRICULA").asLong()).isEqualTo(990001);
        assertThat(guardar.path("OBSERVACIONES_ORIGEN").asInt()).isEqualTo(2);
        assertThat(guardar.path("OBSERVACION").asString())
                .isEqualTo(guardar.path("OBSERVACION_IA").asString())
                .contains("Dimensión Comunicativa: Narra cuentos con secuencia.")
                .endsWith("Felicitaciones a Sofía.");
    }

    @Test
    void noPisaUnTextoModificadoPorElDocente() throws Exception {
        estadoGuardado = "MODIFICADA";
        mvc.perform(post("/ai/observaciones/periodo")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"FK_TMATRICULA\":990001,\"FK_TPERIODO_EVALUACION\":970001}"))
                .andExpect(status().isConflict());
        assertThat(RECIBIDO).doesNotContainKeys("llm", "guardar");
    }

    @Test
    void sinTokenResponde401() throws Exception {
        mvc.perform(post("/ai/observaciones/periodo")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"FK_TMATRICULA\":1,\"FK_TPERIODO_EVALUACION\":1}"))
                .andExpect(r -> assertThat(r.getResponse().getStatus()).isIn(401, 403));
        assertThat(RECIBIDO).isEmpty();
    }

    private static String leer(HttpExchange ex) throws IOException {
        return new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
    }

    private static void responder(HttpExchange ex, String body) throws IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().add("Content-Type", "application/json");
        ex.sendResponseHeaders(200, b.length);
        ex.getResponseBody().write(b);
        ex.close();
    }
}
