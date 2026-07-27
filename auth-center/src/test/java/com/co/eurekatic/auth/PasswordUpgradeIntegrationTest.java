package com.co.eurekatic.auth;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
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
 * Pins the BCrypt → Argon2id migration path.
 *
 * <p>The migration is lazy by design (see
 * {@code PasswordUpgradeService}): nobody resets a password, and
 * rows are rewritten one successful login at a time. That makes two
 * things worth pinning, because a regression in either is silent —
 * it looks like a normal login until you inspect the column:
 *
 * <ol>
 *   <li>A pre-migration {@code {bcrypt}} row must still authenticate.
 *       If it didn't, every existing user would be locked out at
 *       deploy time, and the only symptom would be a 401.</li>
 *   <li>After that login the stored hash must actually be
 *       {@code {argon2}}. If {@code setUserDetailsPasswordService}
 *       were dropped from {@code AuthenticationConfig}, logins would
 *       keep working forever and the migration would simply never
 *       happen — no error anywhere.</li>
 * </ol>
 *
 * <h2>Runtime environment</h2>
 * <p>Uses Testcontainers Redis (the refresh-token store is on the
 * login path) and an in-memory H2 datasource, same harness as
 * {@link AccountActivationEnablesLoginIntegrationTest}.
 */
@SpringBootTest(
        classes = AuthCenterApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(locations = "classpath:jwt-test-keys.properties", properties = {
        "spring.datasource.url=jdbc:h2:mem:password-upgrade-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;DB_CLOSE_DELAY=-1",
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
class PasswordUpgradeIntegrationTest {

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

    private WebTestClient webTestClient;

    private void bindWebClient() {
        webTestClient = MockMvcWebTestClient
                .bindToApplicationContext(context)
                .apply(SecurityMockMvcConfigurers.springSecurity())
                .build();
    }

    /**
     * Seeds a user whose password is hashed the way rows looked
     * before the migration: BCrypt cost 12, with the {@code {bcrypt}}
     * prefix that V19 stamped onto the existing rows. We hash it
     * here rather than pasting a literal so the fixture can't drift
     * from the cost the delegating encoder is configured to read.
     */
    private User seedLegacyBcryptUser() {
        String legacyHash = "{bcrypt}" + new BCryptPasswordEncoder(12).encode("s3cret");

        User dana = new User();
        dana.setEmail("dana@example.com");
        dana.setFullName("Dana Example");
        dana.setPassword(legacyHash);
        dana.setEnabled(true);
        dana.setActive(true);
        dana.setLdap(false);
        return userRepository.save(dana);
    }

    @Test
    void legacyBcryptUserCanStillLogIn() {
        bindWebClient();
        seedLegacyBcryptUser();

        webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"dana@example.com\",\"password\":\"s3cret\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK);
    }

    @Test
    void successfulLoginRewritesBcryptHashToArgon2id() {
        bindWebClient();
        seedLegacyBcryptUser();

        webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"dana@example.com\",\"password\":\"s3cret\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK);

        String stored = userRepository.findByEmail("dana@example.com")
                .orElseThrow()
                .getPassword();

        assertThat(stored).startsWith("{argon2}");
    }

    @Test
    void failedLoginLeavesTheLegacyHashUntouched() {
        bindWebClient();
        String before = seedLegacyBcryptUser().getPassword();

        webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"dana@example.com\",\"password\":\"wrong\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);

        // The upgrade hook must sit strictly behind a verified
        // password: a wrong guess that rewrote the row would be a
        // way to overwrite a hash without knowing the password.
        String after = userRepository.findByEmail("dana@example.com")
                .orElseThrow()
                .getPassword();

        assertThat(after).isEqualTo(before);
    }
}
