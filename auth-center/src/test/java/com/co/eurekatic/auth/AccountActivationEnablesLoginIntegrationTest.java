package com.co.eurekatic.auth;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;
import org.springframework.test.web.servlet.client.MockMvcWebTestClient;
import org.springframework.web.context.WebApplicationContext;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Pins the contract between {@code POST /sso-admin/createAccount}
 * (which leaves the user pending: {@code password=null},
 * {@code enabled=false}, {@code token_activation=<UUID>}) and
 * {@code POST /auth/login} via {@link
 * com.co.eurekatic.auth.security.JsonLoginFilter}.
 *
 * <p>The activation endpoint itself lives in sso-admin and is
 * covered by {@link com.co.eurekatic.ssoadmin.SsoAdminIntegrationTest}
 * (see {@code activateAccountEnablesUserWithoutAuth}). This
 * suite covers the OTHER half: after the activation flow
 * completes — whether via the real sso-admin endpoint or, as
 * here, by flipping the row directly to simulate it — the user
 * must be able to log in. We exercise the full Spring context
 * with an in-memory H2 datasource and a Testcontainers Redis
 * instance backing the refresh-token store, mirroring the harness
 * in {@link GroupRolesInTokenIntegrationTest}.
 *
 * <p>Each test creates a fresh {@code charlie} that mirrors the
 * pre-activation state (no password, disabled flag), performs
 * login (expected 401), then performs the activation-equivalent
 * flip directly via {@code userRepository.save} (this stands in
 * for the cross-module {@code POST /sso-admin/activateAccount}
 * that lives elsewhere), and finally retries login (expected
 * 200 + JWT + correct username in claims).
 *
 * <h2>Runtime environment</h2>
 * <p>This test uses Testcontainers Redis. It requires a Docker
 * daemon reachable via the standard socket: Linux hosts and
 * macOS hosts running Docker Desktop work out of the box. On
 * Colima (QEMU-backed VM), the Testcontainers Ryuk reaper
 * fails to {@code mkdir docker.sock: operation not supported},
 * because Colima's QEMU filesystem does not allow socket
 * bind-mounts. This is a known limitation of Colima +
 * testcontainers and affects every Testcontainers-using test
 * in this repo (see also {@link GroupRolesInTokenIntegrationTest}),
 * not a defect of this test.
 *
 * <p>Locally on Colima, run with
 * {@code TESTCONTAINERS_RYUK_DISABLED=true} (and
 * {@code DOCKER_HOST=unix:///Users/apple/.colima/default/docker.sock}
 * if Docker isn't on the default socket) to bypass the reaper
 * and let the Redis container start. CI runs on Linux where
 * the standard socket is mounted natively — the flag is not
 * needed there.
 */
@SpringBootTest(
        classes = AuthCenterApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(properties = {
        "spring.datasource.url=jdbc:h2:mem:auth-center-account-activation-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        // Same rationale as AuthCenterIntegrationTest — keep the
        // login flow talking to the DB so the activation flip is
        // observable on the second /login call.
        "sso.session.user-roles.enabled=false",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
@Testcontainers
class AccountActivationEnablesLoginIntegrationTest {

    @Container
    @SuppressWarnings("resource")
    static final GenericContainer<?> REDIS = new GenericContainer<>(
            DockerImageName.parse("redis:7-alpine"))
            .withCommand("redis-server", "--save", "", "--appendonly", "no")
            .withExposedPorts(6379);

    @DynamicPropertySource
    static void redisProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.data.redis.host", REDIS::getHost);
        registry.add("spring.data.redis.port",
                () -> REDIS.getMappedPort(6379).toString());
    }

    @Autowired
    WebApplicationContext context;

    @Autowired
    UserRepository userRepository;

    @Autowired
    PasswordEncoder passwordEncoder;

    @Autowired
    ObjectMapper mapper;

    private WebTestClient webTestClient;

    /**
     * Seeds a {@code charlie} that is exactly the state
     * {@code POST /sso-admin/createAccount} produces today:
     * {@code active=true}, {@code enabled=false}, no password
     * column, a fresh activation token. Returns the user row so
     * each test can flip the post-activation state on top of it
     * without re-seeding.
     */
    private User seedPendingUser() {
        userRepository.deleteAll();

        User u = new User();
        u.setEmail("charlie@example.com");
        u.setFullName("Charlie Pending");
        // Mirrors UserAdminService.createAccount lines 103-110
        // (the modernized password-less flow): no setPassword()
        // call, so the column stays null until
        // /activateAccount stamps it.
        u.setActive(true);
        u.setEnabled(false);
        u.setLdap(false);
        u.setTokenActivation(UUID.randomUUID().toString());
        return userRepository.save(u);
    }

    private void loginExpectingStatus(String email, String password, HttpStatus expected) {
        webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(String.format(
                        "{\"email\":\"%s\",\"password\":\"%s\"}",
                        email, password))
                .exchange()
                .expectStatus().isEqualTo(expected);
    }

    private void bindWebClient() {
        webTestClient = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(SecurityMockMvcConfigurers.springSecurity())
                .build();
    }

    @Test
    void loginBeforeActivationIsRejected() {
        bindWebClient();
        seedPendingUser();

        // The pending user has enabled=false (and null password
        // — AppUserDetailsService.loadUserByUsername short-
        // circuits on the isEnabled check before ever hitting
        // PasswordEncoder.matches). Either way, /login must
        // return 401, NOT 200.
        loginExpectingStatus("charlie@example.com", "newpass1", HttpStatus.UNAUTHORIZED);
    }

    @Test
    void loginAfterActivationSucceedsAndIssuesJwt() throws Exception {
        bindWebClient();
        User pending = seedPendingUser();

        // Simulate the work that UserAdminService.activateAccount
        // does in sso-admin: BCrypt the typed password, enable
        // the user, clear the activation token. We do it via the
        // repository directly because activateAccount lives in
        // another module — the cross-module integration is
        // pinned separately at the wire level (the
        // activateAccount… integration test in sso-admin).
        pending.setPassword(passwordEncoder.encode("newpass1"));
        pending.setEnabled(true);
        pending.setActive(true);
        pending.setTokenActivation(null);
        userRepository.save(pending);

        byte[] body = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"charlie@example.com\",\"password\":\"newpass1\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class)
                .getResponseBodyContent();

        // Wire shape — TokenResponse JSON.
        JsonNode json = mapper.readTree(body);
        String token = json.get("token").asText();
        assertThat(token).isNotBlank();

        // Decode the JWT payload and confirm the username claim.
        String[] parts = token.split("\\.");
        assertThat(parts).hasSize(3);
        String payloadJson = new String(
                java.util.Base64.getUrlDecoder().decode(parts[1]),
                StandardCharsets.UTF_8);
        JsonNode claims = mapper.readTree(payloadJson);
        assertThat(claims.get("sub").asText()).isEqualTo("charlie@example.com");
    }

    @Test
    void loginAfterActivationButWithWrongPasswordIsRejected() {
        bindWebClient();
        User pending = seedPendingUser();
        pending.setPassword(passwordEncoder.encode("newpass1"));
        pending.setEnabled(true);
        pending.setActive(true);
        pending.setTokenActivation(null);
        userRepository.save(pending);

        // Right username, wrong password — must NOT authenticate.
        // Pin so a future change to AppUserDetailsService can't
        // silently weaken the password check.
        loginExpectingStatus("charlie@example.com", "wrong-pass", HttpStatus.UNAUTHORIZED);
    }
}
