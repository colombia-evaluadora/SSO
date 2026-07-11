package com.co.eurekatic.gateway;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.gateway.routing.UserForwardingGlobalFilter;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.cloud.client.ServiceInstance;
import org.springframework.cloud.client.discovery.ReactiveDiscoveryClient;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.http.HttpHeaders;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;
import reactor.core.publisher.Flux;

import java.util.LinkedHashSet;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * End-to-end integration test for the api-gateway. Verifies the
 * SecurityWebFilterChain and bean wiring without needing a real
 * downstream service.
 *
 * <ol>
 *   <li>{@code /actuator/health} and {@code /actuator/info} are
 *       public and return 200 without a token.</li>
 *   <li>Unauthenticated requests on any other path return 401.</li>
 *   <li>An invalid Bearer token returns 401.</li>
 *   <li>The dynamic discovery locator properties are configured
 *       correctly.</li>
 *   <li>The {@link UserForwardingGlobalFilter} bean is registered.</li>
 *   <li>The {@link JwtTokenService} bean is wired (smoke test).</li>
 * </ol>
 *
 * <p>The {@code UserForwardingGlobalFilter}'s header-injection logic
 * is covered by a unit test in
 * {@link UserForwardingGlobalFilterTest}, since wiring a real
 * round-trip to a stub backend requires either a fixed port or
 * dynamic route injection — both of which add complexity that
 * belongs in a separate "gateway + downstream" integration test.
 */
@SpringBootTest(
        classes = ApiGatewayIntegrationTest.TestApp.class,
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT
)
@TestPropertySource(properties = {
        "sso.jwt.secret=gateway-integration-test-secret-32-bytes-or-more-please-thank-you-1234",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
class ApiGatewayIntegrationTest {

    @LocalServerPort
    int gatewayPort;

    @Autowired
    JwtTokenService jwt;

    @Autowired
    JwtProperties jwtProperties;

    @Autowired
    ObjectMapper mapper;

    @Autowired
    UserForwardingGlobalFilter userForwardingGlobalFilter;

    @Autowired
    org.springframework.cloud.gateway.discovery.DiscoveryLocatorProperties discoveryLocatorProperties;

    @Test
    void healthEndpointIsPublic() {
        webTestClient().get().uri("/actuator/health").exchange()
                .expectStatus().is2xxSuccessful();
    }

    @Test
    void infoEndpointIsPublic() {
        webTestClient().get().uri("/actuator/info").exchange()
                .expectStatus().is2xxSuccessful();
    }

    @Test
    void protectedPathWithoutTokenReturns401() {
        webTestClient().get().uri("/protected").exchange()
                .expectStatus().isEqualTo(401);
    }

    @Test
    void protectedPathWithInvalidTokenReturns401() {
        webTestClient()
                .get()
                .uri("/protected")
                .header(HttpHeaders.AUTHORIZATION, "Bearer not-a-jwt")
                .exchange()
                .expectStatus().isEqualTo(401);
    }

    @Test
    void validTokenOnPublicEndpointIsAccepted() {
        // /actuator/health is public, so this just verifies the
        // gateway doesn't choke on a well-formed token in the
        // Authorization header. A protected-path round-trip is
        // covered by UserForwardingGlobalFilterTest.
        String token = jwt.issueAccessToken("alice", new LinkedHashSet<>(Set.of("USER")));
        webTestClient()
                .get()
                .uri("/actuator/health")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().is2xxSuccessful();
    }

    @Test
    void dynamicDiscoveryLocatorIsConfigured() {
        assertThat(discoveryLocatorProperties).isNotNull();
        assertThat(discoveryLocatorProperties.isEnabled()).isTrue();
        assertThat(discoveryLocatorProperties.isLowerCaseServiceId()).isTrue();
        // The include expression should filter out the gateway itself
        // to prevent self-referential routes.
        assertThat(discoveryLocatorProperties.getIncludeExpression())
                .contains("api-gateway");
    }

    @Test
    void userForwardingGlobalFilterIsBeanRegistered() {
        assertThat(userForwardingGlobalFilter).isNotNull();
    }

    @Test
    void jwtTokenServiceIsWiredWithProperties() {
        // Smoke test: the bean is created with the test secret and
        // can mint + parse a token. This is also covered by
        // JwtTokenServiceTest in the common module, but here we
        // verify the gateway's wiring (JwtSupportConfig +
        // @EnableConfigurationProperties(JwtProperties.class)).
        String token = jwt.issueAccessToken("alice", new LinkedHashSet<>(Set.of("USER")));
        assertThat(token).isNotBlank();
        assertThat(jwt.parse(token).email()).isEqualTo("alice");
        assertThat(jwtProperties.headerName()).isEqualTo("Authorization");
        assertThat(jwtProperties.tokenPrefix()).isEqualTo("Bearer ");
    }

    /* ====================== helpers ====================== */

    private WebTestClient webTestClient() {
        return WebTestClient.bindToServer()
                .baseUrl("http://localhost:" + gatewayPort)
                .build();
    }

    /**
     * Test entry point. Wraps the production application class and
     * adds a stub {@link ReactiveDiscoveryClient} so the dynamic
     * route locator auto-config is satisfied without a real Eureka
     * server. The stub returns empty {@link Flux} for
     * {@code getServices()}.
     */
    @TestConfiguration
    static class TestApp {

        @Bean
        public ApiGatewayApplication main() {
            return new ApiGatewayApplication();
        }

        @Bean
        @Primary
        public ReactiveDiscoveryClient stubDiscoveryClient() {
            return new ReactiveDiscoveryClient() {
                @Override
                public Flux<String> getServices() {
                    return Flux.empty();
                }

                @Override
                public Flux<ServiceInstance> getInstances(String serviceId) {
                    return Flux.empty();
                }

                @Override
                public String description() {
                    return "stub-discovery-client";
                }
            };
        }
    }
}
