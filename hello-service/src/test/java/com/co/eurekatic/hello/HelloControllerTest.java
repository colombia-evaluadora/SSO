package com.co.eurekatic.hello;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webflux.test.autoconfigure.WebFluxTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * Slice test for {@link HelloController}. Boots only the WebFlux
 * layer (no security, no Eureka, no JPA) and verifies the
 * controller's response shape and that the
 * {@code X-Authenticated-*} headers — set by the api-gateway's
 * global filter — are surfaced correctly.
 *
 * <p>End-to-end testing of the full flow (gateway → hello-service
 * with a real JWT) belongs in a docker-compose integration test
 * once the compose file lands.
 */
@WebFluxTest(controllers = HelloController.class)
@TestPropertySource(properties = {
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
class HelloControllerTest {

    @Autowired
    WebTestClient webTestClient;

    @Test
    void helloGreetsTheAuthenticatedUser() {
        webTestClient.get().uri("/api/hello")
                .header(HelloController.HEADER_USER, "alice")
                .header(HelloController.HEADER_ROLES, "USER,ADMIN")
                .header(HelloController.HEADER_TOKEN_TYPE, "access")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.message").isEqualTo("Hello, alice!")
                .jsonPath("$.user").isEqualTo("alice")
                .jsonPath("$.roles[0]").isEqualTo("USER")
                .jsonPath("$.roles[1]").isEqualTo("ADMIN")
                .jsonPath("$.tokenType").isEqualTo("access")
                .jsonPath("$.service").isEqualTo("hello-service")
                .jsonPath("$.timestamp").exists();
    }

    @Test
    void helloFallsBackToWorldWhenNoUserHeader() {
        // If a request somehow arrives at this service without the
        // gateway-injected X-Authenticated-User header (which
        // should never happen in production, but might happen in
        // local testing or via a misconfigured route), the
        // controller still returns 200 with "world" as the user.
        webTestClient.get().uri("/api/hello")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.user").isEqualTo("world")
                .jsonPath("$.message").isEqualTo("Hello, world!");
    }

    @Test
    void helloHandlesBlankUserHeader() {
        webTestClient.get().uri("/api/hello")
                .header(HelloController.HEADER_USER, "   ")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.user").isEqualTo("world");
    }

    @Test
    void helloHandlesEmptyRolesHeader() {
        webTestClient.get().uri("/api/hello")
                .header(HelloController.HEADER_USER, "bob")
                .header(HelloController.HEADER_ROLES, "")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.user").isEqualTo("bob")
                .jsonPath("$.roles.length()").isEqualTo(0);
    }

    @Test
    void helloTrimsAndFiltersBlankRoles() {
        webTestClient.get().uri("/api/hello")
                .header(HelloController.HEADER_USER, "bob")
                .header(HelloController.HEADER_ROLES, " USER , , ADMIN ,  ")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.roles.length()").isEqualTo(2)
                .jsonPath("$.roles[0]").isEqualTo("USER")
                .jsonPath("$.roles[1]").isEqualTo("ADMIN");
    }

    @Test
    void whoamiEchoesAllHeaders() {
        webTestClient.get().uri("/api/whoami")
                .header(HelloController.HEADER_USER, "carol")
                .header(HelloController.HEADER_ROLES, "USER")
                .header(HelloController.HEADER_TOKEN_TYPE, "api")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.x-authenticated-user").isEqualTo("carol")
                .jsonPath("$.x-authenticated-roles").isEqualTo("USER")
                .jsonPath("$.x-authenticated-token-type").isEqualTo("api")
                .jsonPath("$.service").isEqualTo("hello-service");
    }

    @Test
    void whoamiReturnsNullsWhenNoHeaders() {
        // /api/whoami is the diagnostic endpoint: it should return
        // 200 with nulls, not 401, because the controller itself
        // does not enforce auth — that's the gateway's job. In
        // production, the gateway's default-deny rule will have
        // already returned 401 for requests missing a valid
        // X-Authenticated-User.
        webTestClient.get().uri("/api/whoami")
                .exchange()
                .expectStatus().isOk()
                .expectBody()
                .jsonPath("$.x-authenticated-user").isEqualTo(null)
                .jsonPath("$.x-authenticated-roles").isEqualTo(null);
    }
}
