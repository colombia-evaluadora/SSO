package com.co.eurekatic.query;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.catalog.WriteDefinition;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
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
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;

/**
 * End-to-end integration test for the read and write
 * paths.
 *
 * <p>Boots the full Spring context against an in-memory H2
 * database (so we don't need Docker for tests) and stubs
 * the {@link CatalogClient} so the real sso-admin isn't
 * required.
 *
 * <p>Why we test through WebTestClient and not just the
 * services directly: the controller layer wires the
 * SecurityFilterChain, the JWT filter, and the
 * GlobalExceptionHandler — those are what the
 * authorization and error-shape contracts are about, and
 * skipping them in tests lets regressions slip through.
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
        "query.datasources.entries.postgres.url=jdbc:h2:mem:query-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
        "query.datasources.entries.postgres.driver-class-name=org.h2.Driver",
        "query.datasources.entries.postgres.username=sa",
        "query.datasources.entries.postgres.password=",
        "query.datasources.entries.postgres.maximum-pool-size=4",
        "query.catalog.base-url=http://stubbed.invalid",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
class QueryServiceIntegrationTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterChainProxy springSecurityFilterChain;
    @Autowired(required = false)
    @org.springframework.beans.factory.annotation.Qualifier("queryJdbcTemplates")
    Map<String, NamedParameterJdbcTemplate> jdbcTemplates;
    @Autowired JwtTokenService jwtService;
    @Autowired ObjectMapper mapper;
    @Autowired PasswordEncoder passwordEncoder;

    @MockitoBean(enforceOverride = true)
    CatalogClient catalogClient;

    private WebTestClient client;

    @BeforeEach
    void setUp() {
        client = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(springSecurity(springSecurityFilterChain))
                .build();

        // Diagnostic — prints whatever map we got so we
        // can see whether my bean won the race against
        // Boot's autoconfigured DataSource.
        JdbcTemplate jdbc = jdbcTemplates.get("postgres").getJdbcTemplate();
        // Seed a tiny table so SELECT / INSERT / UPDATE
        // have something to chew on.
        jdbc.execute("DROP TABLE IF EXISTS users");
        jdbc.execute(
                "CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(64), email VARCHAR(64))");
        jdbc.update("INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                1, "Alice", "alice@example.com");
        jdbc.update("INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                2, "Bob", "bob@example.com");

        // Default mocks — individual tests override.
        when(catalogClient.fetchQuery(any(), eq("missing")))
                .thenThrow(new org.springframework.web.server.ResponseStatusException(
                        org.springframework.http.HttpStatus.NOT_FOUND,
                        "not found"));
    }

    /* ====================== read path ====================== */

    @Test
    void getQueryRejectsAnonymousWith403() {
        client.post().uri("/query")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q1", "params", Map.of()))
                .exchange()
                .expectStatus().isForbidden();
    }

    @Test
    void postQueryRunsSelectAndReturnsRows() throws Exception {
        when(catalogClient.fetchQuery(any(), eq("q1"))).thenReturn(
                new QueryDefinition(1L, "q1", "SELECT id, name FROM users ORDER BY id",
                        "postgres", false, false, null, null, null));

        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q1", "params", Map.of()))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(2);
                    assertThat(arr.get(0).get("name").asText()).isEqualTo("Alice");
                    assertThat(arr.get(1).get("name").asText()).isEqualTo("Bob");
                }));
    }

    @Test
    void postQueryRejectsNonSelectSql() {
        when(catalogClient.fetchQuery(any(), eq("q-evil"))).thenReturn(
                new QueryDefinition(2L, "q-evil", "DELETE FROM users",
                        "postgres", false, false, null, null, null));

        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q-evil", "params", Map.of()))
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .value(body -> assertThat(new String(body)).contains("SELECT"));
    }

    @Test
    void postServiceFitWrapsRowsInEnvelope() throws Exception {
        when(catalogClient.fetchQuery(any(), eq("q2"))).thenReturn(
                new QueryDefinition(3L, "q2", "SELECT id FROM users ORDER BY id",
                        "postgres", false, false, null, null, null));

        client.post().uri("/serviceFit")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q2", "params", Map.of(), "limit", 1))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(env -> {
                    assertThat(env.get("rows")).hasSize(1);
                    assertThat(env.get("uuid").asText()).isEqualTo("q2");
                    assertThat(env.get("total").asInt()).isEqualTo(1);
                }));
    }

    @Test
    void publicServiceAllowsAnonymousForPublicEndQuery() throws Exception {
        when(catalogClient.fetchQuery(any(), eq("q-public"))).thenReturn(
                new QueryDefinition(4L, "q-public",
                        "SELECT count(*) AS n FROM users",
                        "postgres", true /* publicEnd */, false, null, null, null));

        // No Authorization header — /public/service is
        // permitAll.
        client.post().uri("/public/service")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q-public", "params", Map.of()))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(1);
                    assertThat(arr.get(0).get("n").asInt()).isEqualTo(2);
                }));
    }

    /* ====================== write path ====================== */

    @Test
    void postWriteRequiresAuth() {
        client.post().uri("/write")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "wd-1", "columns", Map.of()))
                .exchange()
                .expectStatus().isForbidden();
    }

    @Test
    void postWriteInsertRunsAndReturnsRowsAffected() throws Exception {
        when(catalogClient.fetchWrite(any(), eq("wd-1"))).thenReturn(
                new WriteDefinition(1L, "wd-1", "INSERT", "users",
                        List.of("id", "name", "email"), List.of("id")));

        client.post().uri("/write")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of(
                        "uuid", "wd-1",
                        "columns", Map.of(
                                "id", 3,
                                "name", "Carol",
                                "email", "carol@example.com")))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(resp -> {
                    assertThat(resp.get("rowsAffected").asInt()).isEqualTo(1);
                    assertThat(resp.get("uuid").asText()).isEqualTo("wd-1");
                }));

        // Verify the row landed.
        Integer count = jdbcTemplates.get("postgres").getJdbcTemplate()
                .queryForObject("SELECT count(*) FROM users WHERE id = 3", Integer.class);
        assertThat(count).isEqualTo(1);
    }

    @Test
    void postWriteRejectsUndeclaredColumn() {
        when(catalogClient.fetchWrite(any(), eq("wd-strict"))).thenReturn(
                new WriteDefinition(2L, "wd-strict", "INSERT", "users",
                        List.of("id", "name"), List.of("id")));

        // Request sends an extra column that the catalog
        // doesn't declare.
        client.post().uri("/write")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of(
                        "uuid", "wd-strict",
                        "columns", Map.of(
                                "id", 99,
                                "name", "Eve",
                                "evil_column", "DROP TABLE users")))
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .value(body -> assertThat(new String(body)).contains("Unknown column"));
    }

    @Test
    void postWriteRejectsMissingColumn() {
        when(catalogClient.fetchWrite(any(), eq("wd-strict2"))).thenReturn(
                new WriteDefinition(3L, "wd-strict2", "INSERT", "users",
                        List.of("id", "name", "email"), List.of("id")));

        // Catalog declares email but the request omits it.
        client.post().uri("/write")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of(
                        "uuid", "wd-strict2",
                        "columns", Map.of(
                                "id", 99,
                                "name", "Eve")))
                .exchange()
                .expectStatus().isBadRequest()
                .expectBody(byte[].class)
                .value(body -> assertThat(new String(body)).contains("Missing column"));
    }

    /* ====================== helpers ====================== */

    private String tokenFor(String username, String... roles) {
        Set<String> roleSet = new LinkedHashSet<>(List.of(roles));
        return jwtService.issueAccessToken(username, roleSet);
    }

    /**
     * Parses the body as JSON and feeds the resulting
     * {@code JsonNode} to the assertion. Wraps
     * {@link java.io.IOException} as a runtime exception so
     * the lambda body stays a clean {@code Consumer<byte[]>}.
     */
    private Consumer<byte[]> jsonBody(Consumer<com.fasterxml.jackson.databind.JsonNode> assertion) {
        return body -> {
            try {
                assertion.accept(mapper.readTree(body));
            } catch (java.io.IOException e) {
                throw new RuntimeException("Failed to parse response JSON", e);
            }
        };
    }
}