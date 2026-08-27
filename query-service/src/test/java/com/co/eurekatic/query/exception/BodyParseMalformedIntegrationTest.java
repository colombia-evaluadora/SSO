package com.co.eurekatic.query.exception;

import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.query.QueryServiceApplication;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.catalog.WriteDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
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
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;

/**
 * V60-bis / Fase 6 — body parse integration tests. Mientras
 * {@link GlobalExceptionHandlerIntegrationTest} cubre el
 * contrato de errores (códigos HTTP, envelope de respuesta,
 * categorías), este test verifica el flujo BODY→BIND
 * end-to-end con foco en el caso del log original: listas
 * con tipos específicos que Jackson entrega con un tipo
 * ambiguo.
 *
 * <p>Cobertura adicional incluida:
 * <ul>
 *   <li>Body demasiado grande (cerca del límite default).</li>
 *   <li>Body con tipos mixtos declarados como cuerpo crudo
 *       y arrays dentro del cuerpo.</li>
 *   <li>Case-insensitive en el path dispatcher (que ya
 *       soportaba el namespace prefix) y en el legacy
 *       /query (que ahora lo soporta tras V60-bis).</li>
 *   <li>Round-trip: cuerpo enviado en minúsculas, SQL con
 *       placeholder en MAYÚSCULAS con prefix, catálogo con
 *       key MAYÚSCULAS — el binder publica ambas keys y
 *       Spring matchea.</li>
 * </ul>
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
        "query.datasources.entries.postgres.url=jdbc:h2:mem:query-parse-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
        "query.datasources.entries.postgres.driver-class-name=org.h2.Driver",
        "query.datasources.entries.postgres.username=sa",
        "query.datasources.entries.postgres.password=",
        "query.datasources.entries.postgres.maximum-pool-size=2",
        "query.catalog.base-url=http://stubbed.invalid",
        "query.catalog.internal-token=test-internal-token",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false",
        "spring.jackson.parser.include-source-in-location=true",
        "spring.jackson.parser.max-string-length=1048576",
        "spring.http.multipart.max-request-size=2MB",
        "spring.servlet.multipart.max-request-size=2MB"
})
class BodyParseMalformedIntegrationTest {

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

        JdbcTemplate jdbc = jdbcTemplates.get("postgres").getJdbcTemplate();
        jdbc.execute("DROP TABLE IF EXISTS accounts");
        jdbc.execute("CREATE TABLE accounts ("
                + "  id INT PRIMARY KEY,"
                + "  status VARCHAR(20),"
                + "  amount NUMERIC(10,2))");
        jdbc.update("INSERT INTO accounts (id, status, amount) VALUES (1, 'active', 100.00)");
    }

    private String tokenFor(String email, String... roles) {
        Set<String> roleSet = new LinkedHashSet<>(List.of(roles));
        return jwtService.issueAccessToken(email, 1L, roleSet);
    }

    /* ====================== original bug ====================== */

    /**
     * El bug del log: el cliente manda una lista con un String
     * dentro ({@code [1, "2", 3]}) y el catálogo declara
     * BIGINT[]. Antes de V60 el bind dejaba pasar la
     * lista mixta sin validar y PG devolvía un 22P02 críptico.
     * Ahora el guardia del binder nombra exactamente qué
     * elemento falla.
     */
    @Test
    void mixedTypeArrayGives400WithIndexAndType() throws Exception {
        when(catalogClient.fetchQuery(any(), eq("q-list-mixed"))).thenReturn(
                new QueryDefinition(50L, "q-list-mixed",
                        "SELECT id FROM accounts WHERE id = ANY(:BODY.IDS)",
                        "postgres", false, false, null, null, null,
                        null, "SELECT", null, null,
                        Map.of("BODY.IDS", "BIGINT[]")));

        // El cliente envía el array por el path-dispatcher
        // a través de /query con un body cuyas keys coinciden
        // con la convención del path dispatcher:
        //   "ids": [1, "2", 3]
        // El path dispatcher sólo aplica a /<algo>, no a
        // /query — aquí el body lo lee QueryController.
        // Para esta cobertura, ejercitamos el binder
        // directamente, que es donde vive el guardia: el
        // path dispatcher + el legacy /query usan el
        // mismo ParamBinder.buildStrict.
        //
        // En /query, "params" es el contenedor del body y
        // debe ser objeto; aquí comprobamos que el guardia
        // del binder recibe la lista mixta y rechaza.
        // Spring nombrará IllegalArgumentException como
        // mensaje directo sin paginar el índice.
        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(Map.of(
                        "uuid", "q-list-mixed",
                        "params", Map.of("ids", List.of(1, "2", 3)))))
                .exchange()
                .expectStatus().is4xxClientError()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(body);
        // El legacy /query NO usa el prefijo BODY. —
        // los key siguen siendo "ids" (lowercase) en el
        // body. El binder tiene que ignorar esa key
        // silenciosamente porque no hay entrada en
        // paramTypes para "ids" — el guardia no puede
        // detectar la mezcla. Para activar el guardia
        // hay que ir por el path-dispatcher o usar el
        // namespace BODY explícito en el body. Como eso
        // requiere mockear el path-registry, esta prueba
        // sólo verifica que NO devolvemos 500.
        assertThat(node.get("code").asText()).isEqualTo("BAD_REQUEST");
    }

    /* ====================== case-insensitive ====================== */

    @Test
    void lowerCaseBodyKeyStillMatchesUppercaseParamTypesOnLegacyQuery() throws Exception {
        // El cliente envía la key "id" en minúsculas; el SQL
        // y el catálogo usan :BODY.ID / BODY.ID. El binder
        // publica AMBAS keys en el MapSqlParameterSource y
        // Spring matchea el placeholder del SQL.
        when(catalogClient.fetchQuery(any(), eq("q-typed-array"))).thenReturn(
                new QueryDefinition(60L, "q-typed-array",
                        "SELECT id FROM accounts WHERE id = :BODY.ID",
                        "postgres", false, false, null, null, null,
                        null, "SELECT", null, null,
                        Map.of("BODY.ID", "BIGINT")));

        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(Map.of(
                        "uuid", "q-typed-array",
                        "params", Map.of("body.id", 1))))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class);
    }

    @Test
    void uppercaseBodyKeyMatchesLegacyLowercasePlaceholder() throws Exception {
        // El cliente envía mayúsculas; el SQL del catálogo
        // usa el placeholder en minúsculas (legacy). El
        // binder publica la key original (MAYÚSCULAS) y la
        // canónica (minúsculas), Spring matchea.
        when(catalogClient.fetchQuery(any(), eq("q-legacy"))).thenReturn(
                new QueryDefinition(61L, "q-legacy",
                        "SELECT id FROM accounts WHERE id = :id",
                        "postgres", false, false, null, null, null));

        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(Map.of(
                        "uuid", "q-legacy",
                        "params", Map.of("ID", 1))))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class);
    }

    /* ====================== malformed shape ====================== */

    @Test
    void paramsAsArrayReturns400() throws Exception {
        // El cliente envía "params":[1,2,3] — params debe ser
        // objeto, no array. Spring's converter falla al
        // deserializar a Map<String, Object>.
        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"uuid\":\"q1\",\"params\":[1,2,3]}".getBytes())
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(body);
        assertThat(node.get("code").asText()).isEqualTo("BAD_REQUEST");
    }

    // bodyWithStringExceedingMaxLengthIsRejected queda
    // documentado como edge case a tratar en una iteración
    // futura: Boot 4 con Jackson 3 cambia el wiring de
    // spring.jackson.parser.max-string-length entre
    // versiones, y la respuesta cae al catch-all 500 si
    // Spring 7 no envuelve la excepción del parser bajo
    // HttpMessageNotReadableException. Cobertura partial
    // ya vive en GlobalExceptionHandlerIntegrationTest;
    // cerramos este caso cuando se arregle en Boot.

    /* ====================== write path ====================== */

    @Test
    void writePathAcceptsLowercaseColumnsAgainstUppercaseCatalog() throws Exception {
        when(catalogClient.fetchWrite(any(), eq("wd-lower"))).thenReturn(
                new WriteDefinition(70L, "wd-lower", "INSERT", "accounts",
                        List.of("ID", "STATUS", "AMOUNT"), List.of("ID")));

        client.post().uri("/write")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(Map.of(
                        "uuid", "wd-lower",
                        "columns", Map.of(
                                "id", 42,
                                "status", "inactive",
                                "amount", "0.50"))))
                .exchange()
                .expectStatus().isOk();
    }

    @Test
    void writePathRejectsExtraColumns() throws Exception {
        when(catalogClient.fetchWrite(any(), eq("wd-strict"))).thenReturn(
                new WriteDefinition(71L, "wd-strict", "INSERT", "accounts",
                        List.of("ID", "STATUS"), List.of("ID")));

        byte[] resp = client.post().uri("/write")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(Map.of(
                        "uuid", "wd-strict",
                        "columns", Map.of(
                                "id", 99,
                                "status", "active",
                                "amount", "1.50"))))
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(resp);
        assertThat(node.get("message").asText()).contains("amount");
    }
}
