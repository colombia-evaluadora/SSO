package com.co.eurekatic.query;

import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
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

import java.util.Map;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;

/**
 * Same shape as {@link QueryServiceIntegrationTest} but
 * exercises the <b>instance mode</b>: env vars only, no
 * YAML {@code query.datasources.entries.*} — exactly how a
 * container launched by admin-ui looks.
 *
 * <p>The mapping is
 * {@code QUERY_DS_DIALECT=postgres} →
 * {@code query.ds.dialect=postgres} etc., via Spring Boot's
 * standard env-var → property relaxation.
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
        "query.ds.dialect=postgres",
        "query.ds.url=jdbc:h2:mem:instance-mode;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
        "query.ds.driver-class-name=org.h2.Driver",
        "query.ds.username=sa",
        "query.ds.password=",
        "query.ds.maximum-pool-size=4",
        "query.catalog.base-url=http://stubbed.invalid",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
class QueryServiceInstanceModeIntegrationTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterChainProxy springSecurityFilterChain;
    @Autowired
    @org.springframework.beans.factory.annotation.Qualifier("queryJdbcTemplates")
    Map<String, NamedParameterJdbcTemplate> jdbcTemplates;
    @Autowired com.co.eurekatic.common.security.JwtTokenService jwtService;
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

        // Instance mode must yield exactly ONE configured
        // dialect — the one in QUERY_DS_DIALECT. Anything
        // else would be a leak from a stale YAML.
        assertThat(jdbcTemplates).hasSize(1).containsKey("postgres");

        JdbcTemplate jdbc = jdbcTemplates.get("postgres").getJdbcTemplate();
        jdbc.execute("DROP TABLE IF EXISTS users");
        jdbc.execute(
                "CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(64), email VARCHAR(64))");
        jdbc.update("INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                1, "Alice", "alice@example.com");
    }

    @Test
    void instanceModeServesOnlyConfiguredDialect() {
        when(catalogClient.fetchQuery(any(), eq("q1"))).thenReturn(
                new QueryDefinition(1L, "q1",
                        "SELECT id, name FROM users ORDER BY id",
                        "postgres", false, false, null, null, null));

        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q1", "params", Map.of()))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(1);
                    assertThat(arr.get(0).get("name").asText()).isEqualTo("Alice");
                }));
    }

    @Test
    void instanceModeRejectsDialectItDoesntServe() {
        // Catalog says oracle — but this instance is
        // configured for postgres only. JdbcTemplateRegistry
        // raises 502, matching the spec's behavior for a
        // query routed to an unconfigured dialect.
        when(catalogClient.fetchQuery(any(), eq("q-oracle"))).thenReturn(
                new QueryDefinition(2L, "q-oracle",
                        "SELECT 1 FROM dual",
                        "oracle", false, false, null, null, null));

        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("uuid", "q-oracle", "params", Map.of()))
                .exchange()
                .expectStatus().isEqualTo(502);
    }

    private String tokenFor(String username, String... roles) {
        java.util.Set<String> roleSet = new java.util.LinkedHashSet<>(java.util.List.of(roles));
        return jwtService.issueAccessToken(username, roleSet);
    }

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