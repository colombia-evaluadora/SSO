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

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Pins the login error message per account state.
 *
 * <p>The bug this guards against: a user whose account an admin had
 * deactivated typed their correct password and was told
 * "credenciales inválidas". The cause was
 * {@code AppUserDetailsService} using
 * {@code UsernameNotFoundException} for disabled accounts, which
 * {@code DaoAuthenticationProvider} deliberately rewrites to
 * {@code BadCredentialsException}. The fix moved the check into
 * {@code AccountStatusChecker}.
 *
 * <p>It is worth pinning at the wire level rather than unit-testing
 * the checker: the whole failure mode was a message being correct
 * where it was thrown and wrong by the time it reached the client,
 * so only an assertion on the response body actually covers it.
 *
 * <h2>Runtime environment</h2>
 * <p>Testcontainers Redis + in-memory H2, same harness as
 * {@link AccountActivationEnablesLoginIntegrationTest}.
 */
@SpringBootTest(
        classes = AuthCenterApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(locations = "classpath:jwt-test-keys.properties", properties = {
        "spring.datasource.url=jdbc:h2:mem:account-status-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
        "sso.session.user-roles.enabled=false",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
@Testcontainers
class AccountStatusMessageIntegrationTest {

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

    private void bindWebClient() {
        webTestClient = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(SecurityMockMvcConfigurers.springSecurity())
                .build();
    }

    /**
     * A user who WAS active and got deactivated by an admin:
     * {@code active=false}, but the password is still set and
     * correct. This is exactly the case that used to report bad
     * credentials.
     */
    private void seedDeactivatedUser() {
        User erin = new User();
        erin.setEmail("erin@example.com");
        erin.setFullName("Erin Example");
        erin.setPassword(passwordEncoder.encode("s3cret"));
        erin.setEnabled(true);
        erin.setActive(false);
        erin.setLdap(false);
        userRepository.save(erin);
    }

    /** Created but never activated from the email link. */
    private void seedPendingUser() {
        User frank = new User();
        frank.setEmail("frank@example.com");
        frank.setFullName("Frank Example");
        frank.setPassword(passwordEncoder.encode("s3cret"));
        frank.setEnabled(false);
        frank.setActive(true);
        frank.setLdap(false);
        userRepository.save(frank);
    }

    private JsonNode login(String email, String password) throws Exception {
        byte[] body = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"" + email + "\",\"password\":\"" + password + "\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED)
                .returnResult(Void.class)
                .getResponseBodyContent();
        return mapper.readTree(body);
    }

    @Test
    void deactivatedAccountSaysDeactivatedNotBadCredentials() throws Exception {
        bindWebClient();
        seedDeactivatedUser();

        // Correct password on purpose — that is the whole point.
        JsonNode json = login("erin@example.com", "s3cret");

        assertThat(json.get("message").asText()).isEqualTo(
                "Tu cuenta fue inactivada. Contacta al administrador.");
        assertThat(json.get("error").asText()).isEqualTo("account_not_available");
    }

    @Test
    void deactivatedAccountSaysTheSameEvenWithAWrongPassword() throws Exception {
        bindWebClient();
        seedDeactivatedUser();

        // The status check runs before the password check, so the
        // message must not depend on whether the password was right.
        // If it did, the response would become a password oracle for
        // deactivated accounts.
        JsonNode json = login("erin@example.com", "wrong");

        assertThat(json.get("message").asText()).isEqualTo(
                "Tu cuenta fue inactivada. Contacta al administrador.");
    }

    @Test
    void neverActivatedAccountSaysActivateNotDeactivated() throws Exception {
        bindWebClient();
        seedPendingUser();

        JsonNode json = login("frank@example.com", "s3cret");

        assertThat(json.get("message").asText()).contains("aún no ha sido activada");
        assertThat(json.get("error").asText()).isEqualTo("account_not_available");
    }

    @Test
    void genuinelyWrongPasswordStillSaysBadCredentials() throws Exception {
        bindWebClient();

        User gina = new User();
        gina.setEmail("gina@example.com");
        gina.setFullName("Gina Example");
        gina.setPassword(passwordEncoder.encode("s3cret"));
        gina.setEnabled(true);
        gina.setActive(true);
        gina.setLdap(false);
        userRepository.save(gina);

        JsonNode json = login("gina@example.com", "wrong");

        // An active account with a wrong password must NOT get the
        // account-status treatment — it stays generic.
        assertThat(json.get("error").asText()).isEqualTo("authentication_failed");
        assertThat(json.get("message").asText()).doesNotContain("inactivada");
    }

    @Test
    void unknownEmailStillSaysBadCredentials() throws Exception {
        bindWebClient();

        JsonNode json = login("nobody@example.com", "whatever");

        // Spring Security's masking of UsernameNotFoundException must
        // survive this change: a non-existent account still looks
        // exactly like a wrong password.
        assertThat(json.get("error").asText()).isEqualTo("authentication_failed");
    }
}
