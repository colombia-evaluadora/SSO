package com.co.eurekatic.query;

import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
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
 * V31 — end-to-end test for PROCEDURE-mode queries that
 * declare OUT params via {@code outParamNames}.
 *
 * <p>Boots the full query-service Spring context against an
 * in-memory H2 database. Stubs {@link CatalogClient} so the
 * test doesn't depend on sso-admin — the wire shape is what
 * matters here.
 *
 * <p>H2 supports the {@code ALIAS} syntax for stored
 * procedures, but for the OUT-param path we use a regular
 * SELECT with a function call. The test seeds a function
 * {@code get_estado_with_msg(id)} that returns a row + sets
 * the OUT-style behaviour via a side-channel table. The
 * point is to verify the OUT-param plumbing works
 * end-to-end through CallableStatement — the catalog row
 * declares the OUTs, QueryService registers them, and the
 * controller surfaces them under {@code outParams}.
 *
 * <p>Two scenarios:
 * <ol>
 *   <li>PROCEDURE with OUT params → 200 with
 *       {@code { rows: [...], outParams: {status: ..., msg: ...} }}.</li>
 *   <li>PROCEDURE without OUT params → legacy bare-list
 *       shape (no outParams key).</li>
 * </ol>
 */
@SpringBootTest(
        classes = QueryServiceApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(properties = {
        "spring.autoconfigure.exclude="
                + "org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration,"
                + "org.springframework.boot.autoconfigure.jdbc.DataSourceTransactionManagerAutoConfiguration,"
                + "org.springframework.boot.autoconfigure.jdbc.JdbcTemplateAutoConfiguration,"
                + "org.springframework.boot.autoconfigure.orm.jpa.HibernateJpaAutoConfiguration",
        "query.datasources.entries.postgres.enabled=true",
        "query.datasources.entries.postgres.url=jdbc:h2:mem:query-out-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
        "query.datasources.entries.postgres.driver-class-name=org.h2.Driver",
        "query.datasources.entries.postgres.username=sa",
        "query.datasources.entries.postgres.password=",
        "query.datasources.entries.postgres.maximum-pool-size=4",
        "query.catalog.base-url=http://stubbed.invalid",
        "query.catalog.internal-token=test-internal-token",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
class CallableStatementOutParamIntegrationTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterChainProxy springSecurityFilterChain;
    @Autowired(required = false)
    @org.springframework.beans.factory.annotation.Qualifier("queryJdbcTemplates")
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
        jdbc.execute("DROP TABLE IF EXISTS establecimiento");
        jdbc.execute(
                "CREATE TABLE establecimiento ("
                + "  id INT PRIMARY KEY,"
                + "  nombre VARCHAR(120),"
                + "  estado VARCHAR(20))");
        jdbc.update("INSERT INTO establecimiento (id, nombre, estado) "
                + "VALUES (1, 'IE #1', 'activo')");
        jdbc.update("INSERT INTO establecimiento (id, nombre, estado) "
                + "VALUES (2, 'IE #2', 'inactivo')");
    }

    /* ====================== PROCEDURE + OUT params ====================== */

    @Test
    @Disabled("V31 OUT-parameter path needs a real PostgreSQL: H2 has no PG-style CALL proc(...) with registerOutParameter. Re-enable under Testcontainers.")
    void procedureWithOutParamsReturnsEnvelope() throws Exception {
        // The catalog author writes a query that sets two OUT
        // params via a SELECT-with-function pattern (H2
        // doesn't expose CALL-syntax in the same way PG does,
        // so we use a function that returns rows AND writes
        // out-params via a side-channel table the test
        // reads back to validate).
        when(catalogClient.fetchQuery(any(), eq("get-est-out"))).thenReturn(
                new QueryDefinition(
                        1L, "get-est-out",
                        // The query reads the row AND populates
                        // out_status / out_msg by INSERTing into
                        // a side table. Real PG would use
                        // CALL proc(...) — same plumbing.
                        "INSERT INTO _out_params (k, v) VALUES ('status', CASE WHEN EXISTS "
                        + "(SELECT 1 FROM establecimiento WHERE id = :id AND estado = 'activo') "
                        + "THEN 'OK' ELSE 'NOT_FOUND' END); "
                        + "INSERT INTO _out_params (k, v) VALUES ('msg', 'processed id=' || :id); "
                        + "SELECT id, nombre FROM establecimiento WHERE id = :id",
                        "postgres",
                        false, false, null, null, null,
                        null,
                        "PROCEDURE",
                        ":out_status,:out_msg"));

        // Pre-create the side-channel table for the test.
        JdbcTemplate jdbc = jdbcTemplates.get("postgres").getJdbcTemplate();
        jdbc.execute("DROP TABLE IF EXISTS _out_params");
        jdbc.execute("CREATE TABLE _out_params (k VARCHAR(40) PRIMARY KEY, v VARCHAR(200))");

        Map<String, Object> response = postJsonEnvelope("/get-est-out?",
                Map.of("uuid", "get-est-out",
                       "params", Map.of("id", 1)));

        // V31 envelope: rows + outParams
        assertThat(response).containsKeys("rows", "outParams");
        assertThat(response.get("rows")).isInstanceOf(List.class);
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> rows = (List<Map<String, Object>>) response.get("rows");
        assertThat(rows).hasSize(1);
        assertThat(rows.get(0).get("nombre")).isEqualTo("IE #1");

        // OUT values come back keyed by the bare param name
        // (without the leading ":"). The function logic
        // populated them via the side-channel table.
        @SuppressWarnings("unchecked")
        Map<String, Object> out = (Map<String, Object>) response.get("outParams");
        assertThat(out).containsKeys("out_status", "out_msg");
    }

    /* ====================== PROCEDURE without OUT params keeps legacy shape ====================== */

    @Test
    void procedureWithoutOutParamsReturnsRowsOnly() throws Exception {
        when(catalogClient.fetchQuery(any(), eq("get-est-plain"))).thenReturn(
                new QueryDefinition(
                        2L, "get-est-plain",
                        "SELECT id, nombre FROM establecimiento WHERE id = :id",
                        "postgres",
                        false, false, null, null, null,
                        null,
                        "PROCEDURE",
                        /*outParamNames*/ null));

        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(
                        Map.of("uuid", "get-est-plain",
                               "params", Map.of("id", 2))))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();

        JsonNode node = mapper.readTree(body == null ? new byte[0] : body);
        // Legacy shape: bare JSON array of row objects.
        assertThat(node.isArray()).isTrue();
        assertThat(node).hasSize(1);
        assertThat(node.get(0).get("nombre").asText()).isEqualTo("IE #2");
    }

    /* ====================== /query accepts PROCEDURE with OUT (backwards compat) ====================== */

    @Test
    @Disabled("V31 OUT-parameter path needs a real PostgreSQL: H2 has no PG-style CALL proc(...) with registerOutParameter. Re-enable under Testcontainers.")
    void queryEndpointStripsOutParamsForLegacyShape() throws Exception {
        // The bare-list /query endpoint doesn't surface
        // outParams — it's the legacy shape. This test
        // verifies that an OUT-declared PROCEDURE row still
        // returns 200 + the rows, with no envelope wrapper.
        when(catalogClient.fetchQuery(any(), eq("get-est-out-2"))).thenReturn(
                new QueryDefinition(
                        3L, "get-est-out-2",
                        "SELECT id, nombre FROM establecimiento WHERE id = :id",
                        "postgres",
                        false, false, null, null, null,
                        null,
                        "PROCEDURE",
                        ":out_status"));

        byte[] body = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(
                        Map.of("uuid", "get-est-out-2",
                               "params", Map.of("id", 1))))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();

        JsonNode node = mapper.readTree(body);
        assertThat(node.isArray()).isTrue();
        assertThat(node).hasSize(1);
    }

    /* ====================== helpers ====================== */

    @SuppressWarnings("unchecked")
    private Map<String, Object> postJsonEnvelope(String path, Object body) throws Exception {
        byte[] responseBytes = client.post().uri(path)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(body))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        return mapper.readValue(responseBytes, Map.class);
    }

    private String tokenFor(String email, String... roles) {
        Set<String> roleSet = new LinkedHashSet<>(List.of(roles));
        return jwtService.issueAccessToken(email, 1L, roleSet);
    }
}
