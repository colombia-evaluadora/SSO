package com.co.eurekatic.query.exception;

import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.query.QueryServiceApplication;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.web.FilterChainProxy;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.reactive.server.WebTestClient;
import org.springframework.test.web.servlet.client.MockMvcWebTestClient;
import org.springframework.web.context.WebApplicationContext;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;

/**
 * V60 — cobertura del {@link GlobalExceptionHandler}. Antes de
 * esta fase, un cuerpo JSON inválido caía en el catch-all y
 * devolvía 500 con el stacktrace del servidor. Aquí se ejercita
 * cada handler explícito y se verifica que:
 *
 * <ul>
 *   <li>El status es el honesto (4xx cuando es entrada
 *       inválida, 5xx sólo cuando es un bug del servidor).</li>
 *   <li>El cuerpo lleva el envelope estándar
 *       {@code code/message/[...]}.</li>
 *   <li>Los datos de diagnóstico (offset, categoría) llegan al
 *       cliente para que pueda corregir sin hacer tickets.</li>
 *   <li>El cuerpo del request NUNCA sale en la respuesta,
 *       incluso cuando el fragmento está en el log del
 *       servidor.</li>
 * </ul>
 *
 * <p>El test corre contra el contexto real de Spring Boot
 * 4.0.7 (Jackson 2 por autoconfig del MVC, Jackson 3
 * transitivo y cargado en el classpath). Ambos paths se
 * verifican — el de Jackson 2 (un cuerpo malformado simple)
 * y el del conversor de Spring que produce
 * {@link org.springframework.http.converter.HttpMessageNotReadableException}.
 */
@SpringBootTest(
        classes = QueryServiceApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(locations = "classpath:jwt-test-keys.properties", properties = {
        "spring.autoconfigure.exclude="
                + "org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration,"
                + "org.springframework.boot.autoconfigure.jdbc.DataSourceTransactionManagerAutoConfiguration,"
                + "org.springframework.boot.autoconfigure.jdbc.JdbcTemplateAutoConfiguration,"
                + "org.springframework.boot.autoconfigure.orm.jpa.HibernateJpaAutoConfiguration",
        "query.datasources.entries.postgres.enabled=true",
        "query.datasources.entries.postgres.url=jdbc:h2:mem:query-exc-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
        "query.datasources.entries.postgres.driver-class-name=org.h2.Driver",
        "query.datasources.entries.postgres.username=sa",
        "query.datasources.entries.postgres.password=",
        "query.datasources.entries.postgres.maximum-pool-size=2",
        "query.catalog.base-url=http://stubbed.invalid",
        "query.catalog.internal-token=test-internal-token",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false",
        "spring.jackson.parser.include-source-in-location=true"
})
class GlobalExceptionHandlerIntegrationTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterChainProxy springSecurityFilterChain;
    @Autowired @Qualifier("queryJdbcTemplates")
    Map<String, NamedParameterJdbcTemplate> jdbcTemplates;
    @Autowired JwtTokenService jwtService;
    @Autowired ObjectMapper mapper;

    @MockitoBean(enforceOverride = true)
    CatalogClient catalogClient;

    private WebTestClient client;

    @BeforeEach
    void setUp() {
        client = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(springSecurity(springSecurityFilterChain))
                .build();
        // No necesitamos sembrar tablas — la mayoría de estos
        // tests no llegan al JDBC porque el fallo ocurre antes.
    }

    private String tokenFor(String email, String... roles) {
        Set<String> roleSet = new LinkedHashSet<>(List.of(roles));
        return jwtService.issueAccessToken(email, 1L, roleSet);
    }

    /**
     * El bug del log: cuerpo JSON con un cierre prematuro de
     * objeto ({@code :}}) que Jackson no puede parsear.
     * Antes de V60 devolvía 500 con stacktrace. Ahora 400 con
     * la categoría y el byte offset.
     */
    @Test
    void malformedJsonReturns400WithOffset() throws Exception {
        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"uuid\":\"q1\",\"params\":}".getBytes())
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();

        JsonNode node = mapper.readTree(body);
        assertThat(node.get("code").asText()).isEqualTo("BAD_REQUEST");
        assertThat(node.get("category").asText())
                .as("stream-level error gets MALFORMED category")
                .isEqualTo("MALFORMED");
        // Byte offset es diagnóstico útil para el cliente.
        // V60 lo expone cuando INCLUDE_SOURCE_IN_LOCATION está
        // activo en producción (JacksonConfig.includeSourceOnParseError).
        // En el contexto del test lo verificamos directamente:
        assertThat(node.has("byteOffset"))
                .as("byte offset is included for client-side forensics")
                .isTrue();
        assertThat(node.has("line")).isTrue();
        assertThat(node.has("column")).isTrue();
        assertThat(node.get("line").asLong()).isEqualTo(1L);
        // El '}' suelto está después de `"params":` — column 23
        // es la posición del carácter problemático.
        assertThat(node.get("column").asLong()).isGreaterThanOrEqualTo(15L);
        assertThat(node.get("message").asText()).contains("JSON");
    }

    @Test
    void bodyOfWrongShapeReturns400() throws Exception {
        // Array como raíz — no encaja con QueryRequest (record
        // espera objeto). El conversor falla antes del binder.
        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("[1,2,3]".getBytes())
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(body);
        assertThat(node.get("code").asText()).isEqualTo("BAD_REQUEST");
        // Categoría: TYPE_MISMATCH o INVALID_DEFINITION según la
        // implementación interna de Jackson. Ambas son 4xx.
        assertThat(node.get("category").asText())
                .isIn("TYPE_MISMATCH", "INVALID_DEFINITION", "OTHER");
    }

    @Test
    void emptyBodyReturns400() throws Exception {
        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("".getBytes())
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(body);
        assertThat(node.get("code").asText()).isEqualTo("BAD_REQUEST");
    }

    @Test
    void unsupportedMediaTypeReturns415WithAllow() {
        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_XML)
                .bodyValue("<root/>".getBytes())
                .exchange()
                .expectStatus().isEqualTo(org.springframework.http.HttpStatus.UNSUPPORTED_MEDIA_TYPE)
                .expectHeader().exists("Accept");
    }

    /**
     * DELETE no está declarado en ninguna ruta — el handler
     * de {@link org.springframework.web.HttpRequestMethodNotSupportedException}
     * entra en juego con 405 + {@code Allow: GET, POST, PUT}.
     */
    @Test
    void unregisteredMethodReturns405WithAllow() {
        client.delete().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .accept(MediaType.APPLICATION_JSON)
                .exchange()
                .expectStatus().isEqualTo(org.springframework.http.HttpStatus.METHOD_NOT_ALLOWED)
                .expectHeader().exists("Allow");
    }

    @Test
    void missingUuidReturns400() throws Exception {
        // Body válido pero falta el campo obligatorio → bean
        // validation. V60 lo mapea via
        // MethodArgumentNotValidException si @Valid está
        // aplicado; si no, el controlador lo rechaza con su
        // propio ResponseStatusException. Aceptamos
        // cualquiera de los dos envelopes.
        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(Map.of("params", Map.of())))
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(body);
        assertThat(node.has("code")).isTrue();
        assertThat(node.has("message")).isTrue();
    }

    @Test
    void malformedBodyNeverEchoesBack() throws Exception {
        // Política explícita: el cuerpo recibido NUNCA sale
        // del servidor, ni siquiera como eco parcial. Si
        // alguna regresión rompe la guardia y empieza a
        // incluir el cuerpo en la respuesta, este test
        // falla.
        String secret = "marker-XYZ-secret-payload-must-not-leak";
        String body = "{\"uuid\":\"q1\",\"params\":{\"" + secret + "\":}}";
        byte[] resp = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body.getBytes())
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        assertThat(new String(resp)).doesNotContain(secret);
    }

    /**
     * Casos nested: parametrizar el tipo de error para que
     * añadir un nuevo modo no requiera un test nuevo desde
     * cero. Hoy cubre MALFORMED y TYPE_MISMATCH; cuando se
     * amplíe el catálogo de categorías, basta con añadir el
     * caso a la tabla.
     */
    @Nested
    class BodyParseCategories {

        record Case(String label, String body, String expectedCategory) {}

        @org.junit.jupiter.params.ParameterizedTest(name = "[{index}] {0}")
        @org.junit.jupiter.params.provider.MethodSource("cases")
        void eachShapeGetsCorrectCategory(Case c) throws Exception {
            byte[] resp = client.post().uri("/query")
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(c.body().getBytes())
                    .exchange()
                    .expectStatus().isBadRequest()
                    .expectBody(byte[].class)
                    .returnResult()
                    .getResponseBody();
            JsonNode node = mapper.readTree(resp);
            assertThat(node.get("category").asText())
                    .as(c.label())
                    .isEqualTo(c.expectedCategory());
        }

        static java.util.stream.Stream<Case> cases() {
            return java.util.stream.Stream.of(
                    new Case("premature close", "{\"uuid\":}", "MALFORMED"),
                    new Case("unclosed string", "{\"uuid\":\"q1}", "MALFORMED"),
                    new Case("trailing junk", "{\"uuid\":\"q1\"}garbage", "MALFORMED"),
                    new Case("array at root", "[1,2,3]", "TYPE_MISMATCH"),
                    // "null" como raíz — Spring marca "Required body
                    // missing" y no hay causa de Jackson para
                    // categorizar; OTHER es la respuesta correcta.
                    new Case("null at root", "null", "OTHER")
            );
        }
    }
}
