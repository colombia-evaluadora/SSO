package com.co.eurekatic.query;

import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
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
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeast;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;

/**
 * V33 — verifies the Resilience4j protections in
 * query-service end-to-end:
 * <ul>
 *   <li>Bulkhead cap returns 503 when the per-dialect
 *       concurrent / queued calls exceed the (test-overridden)
 *       ceiling.</li>
 *   <li>Rate limiter returns 429 with {@code Retry-After}
 *       when a single principal exceeds the (test-overridden)
 *       RPS cap.</li>
 *   <li>Invalidate endpoint immediately refreshes the
 *       registry — verified by setting up a stub that
 *       returns different templates on the second call.</li>
 * </ul>
 *
 * <p>Limits are configured LOW (bulkhead=1, rate=2rps) so
 * the test deterministically hits the cap. The default
 * (20 / 100rps) is exercised in the dashboard, not in CI.
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
        "query.datasources.entries.postgres.url=jdbc:h2:mem:query-resil-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
        "query.datasources.entries.postgres.driver-class-name=org.h2.Driver",
        "query.datasources.entries.postgres.username=sa",
        "query.datasources.entries.postgres.password=",
        "query.datasources.entries.postgres.maximum-pool-size=4",
        "query.catalog.base-url=http://stubbed.invalid",
        "query.catalog.internal-token=test-internal-token",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false",
        // Tighter limits so the test deterministically hits them.
        "query.resilience.bulkhead.max-concurrent=1",
        "query.resilience.bulkhead.max-queue=0",
        "query.resilience.bulkhead.wait-duration=10ms",
        "query.resilience.rate-limit.rps=2",
        "query.resilience.rate-limit.window=10s"
})
class ResilienceIntegrationTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterChainProxy springSecurityFilterChain;
    @Autowired(required = false)
    @org.springframework.beans.factory.annotation.Qualifier("queryJdbcTemplates")
    Map<String, NamedParameterJdbcTemplate> jdbcTemplates;
    @Autowired JwtTokenService jwtService;
    @Autowired ObjectMapper mapper;
    @Autowired QueryResilience resilience;

    @MockitoBean(enforceOverride = true)
    CatalogClient catalogClient;

    private WebTestClient client;

    @BeforeEach
    void setUp() {
        // Each test gets a fresh Resilience4j state so a
        // previous test's saturated rate limit doesn't bleed
        // into the next one.
        resilience.reset();

        client = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(springSecurity(springSecurityFilterChain))
                .build();

        JdbcTemplate jdbc = jdbcTemplates.get("postgres").getJdbcTemplate();
        jdbc.execute("DROP TABLE IF EXISTS items");
        jdbc.execute("CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(60))");
        jdbc.update("INSERT INTO items (id, name) VALUES (1, 'apple')");

        // whoami + pathTemplates default mocks.
        when(catalogClient.whoami(any())).thenReturn(Map.of(
                "microserviceId", 1,
                "serviceId", "query-service-test",
                "kind", "QUERY",
                "instanceName", "test"));
        when(catalogClient.fetchPathTemplates(anyLong()))
                .thenReturn(List.of());
    }

    /* ====================== Bulkhead ====================== */

    @Test
    void bulkheadOverloadReturns503() throws Exception {
        // The default bulkhead is 1 concurrent + 0 queued.
        // A second concurrent call before the first
        // releases must surface 503 (not 200).
        when(catalogClient.fetchQuery(any(), any())).thenAnswer(inv -> {
            // Simulate a slow query that holds the permit
            // for 200ms. The first call grabs the permit
            // and the test fires a second one immediately.
            Thread.sleep(200);
            return new QueryDefinition(
                    1L, "slow-q",
                    "SELECT 1 FROM items WHERE id = 1",
                    "postgres",
                    false, false, null, null, null,
                    null, "SELECT", null);
        });

        // Fire the first call and DON'T await — it sleeps
        // for 200ms holding the bulkhead permit.
        var firstCall = client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(
                        Map.of("uuid", "slow-q", "params", Map.of())))
                .exchange();

        // The second call should be rejected immediately
        // (bulkhead full) because the first still holds
        // the only permit. We assert on the response
        // status of the second call.
        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("bob", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(
                        Map.of("uuid", "slow-q", "params", Map.of())))
                .exchange()
                .expectStatus().isEqualTo(503);

        // Wait for the first to complete so the test
        // exits cleanly.
        firstCall.expectStatus().isOk();
    }

    /* ====================== Rate limiter ====================== */

    @Test
    void rateLimitOverloadReturns429WithRetryAfter() throws Exception {
        // 2 RPS / principal. Three rapid calls from the
        // same principal should hit the cap.
        when(catalogClient.fetchQuery(any(), any())).thenReturn(
                new QueryDefinition(
                        1L, "q1",
                        "SELECT id FROM items WHERE id = 1",
                        "postgres",
                        false, false, null, null, null,
                        null, "SELECT", null));

        String token = tokenFor("alice", "USER");
        for (int i = 0; i < 2; i++) {
            client.post().uri("/query")
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(mapper.writeValueAsBytes(
                            Map.of("uuid", "q1", "params", Map.of())))
                    .exchange()
                    .expectStatus().isOk();
        }
        // Third call: 429 with Retry-After.
        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(
                        Map.of("uuid", "q1", "params", Map.of())))
                .exchange()
                .expectStatus().isEqualTo(429)
                .expectHeader().value("Retry-After", h -> assertThat(h).isEqualTo("1"));
    }

    @Test
    void rateLimitIsScopedPerPrincipal() throws Exception {
        when(catalogClient.fetchQuery(any(), any())).thenReturn(
                new QueryDefinition(
                        1L, "q1",
                        "SELECT id FROM items WHERE id = 1",
                        "postgres",
                        false, false, null, null, null,
                        null, "SELECT", null));

        // alice burns her 2 permits.
        for (int i = 0; i < 2; i++) {
            client.post().uri("/query")
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("alice", "USER"))
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(mapper.writeValueAsBytes(
                            Map.of("uuid", "q1", "params", Map.of())))
                    .exchange()
                    .expectStatus().isOk();
        }
        // bob still has all his permits — separate key.
        client.post().uri("/query")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("bob", "USER"))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsBytes(
                        Map.of("uuid", "q1", "params", Map.of())))
                .exchange()
                .expectStatus().isOk();
    }

    /* ====================== Invalidate endpoint ====================== */

    @Test
    void invalidateEndpointTriggersImmediateRefresh() throws Exception {
        // First fetchPathTemplates returns one template;
        // the second returns a different one. We assert
        // that the /internal/path-registry/invalidate
        // call triggers the second fetch — proving the
        // endpoint is wired to refresh().
        when(catalogClient.fetchPathTemplates(anyLong()))
                .thenReturn(List.of(
                        new QueryDefinition(
                                1L, "first",
                                "SELECT 1",
                                "postgres",
                                false, false, null, null, null,
                                "/first", "SELECT", null)))
                .thenReturn(List.of(
                        new QueryDefinition(
                                2L, "second",
                                "SELECT 2",
                                "postgres",
                                false, false, null, null, null,
                                "/second", "SELECT", null)));

        // Initial state: registry loaded "first".
        // Trigger an invalidate.
        byte[] body = client.post().uri("/internal/path-registry/invalidate")
                .contentType(MediaType.APPLICATION_JSON)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        JsonNode node = mapper.readTree(body);
        // The second fetchPathTemplates is now in flight /
        // cached; the registry contains "second" + a stale
        // "first" only if the cache is broken. We assert
        // fetchPathTemplates was called at least twice
        // (initial + invalidate).
        verify(catalogClient, atLeast(2)).fetchPathTemplates(anyLong());
        assertThat(node.get("size").asInt()).isEqualTo(1);
    }

    /* ====================== helpers ====================== */

    private String tokenFor(String email, String... roles) {
        Set<String> roleSet = new LinkedHashSet<>(List.of(roles));
        return jwtService.issueAccessToken(email, 1L, roleSet);
    }
}
