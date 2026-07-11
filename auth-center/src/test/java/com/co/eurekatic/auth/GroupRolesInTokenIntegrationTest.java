package com.co.eurekatic.auth;

import com.co.eurekatic.common.entity.Group;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.GroupRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
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

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifies that a role granted ONLY via group membership (no direct
 * {@code role_users} row) still lands in the JWT issued at login.
 *
 * <p>Follows the same harness as {@link AuthCenterIntegrationTest}:
 * full Spring context with an in-memory H2 datasource (Postgres-
 * compatibility mode) and a Testcontainers Redis instance backing
 * the refresh-token store.
 */
@SpringBootTest(
        classes = AuthCenterApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(properties = {
        "spring.datasource.url=jdbc:h2:mem:auth-center-group-roles-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        // Group-roles-in-token assertion needs the resolver to
        // actually load the user-group-role chain — the cache
        // short-circuits that path.
        "sso.session.user-roles.enabled=false",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
@Testcontainers
class GroupRolesInTokenIntegrationTest {

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
    RoleRepository roleRepository;

    @Autowired
    GroupRepository groupRepository;

    @Autowired
    PasswordEncoder passwordEncoder;

    @Autowired
    ObjectMapper mapper;

    private WebTestClient webTestClient;

    @BeforeEach
    void seed() {
        webTestClient = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(SecurityMockMvcConfigurers.springSecurity())
                .build();

        userRepository.deleteAll();
        groupRepository.deleteAll();
        roleRepository.deleteAll();

        Role queryReader = new Role();
        queryReader.setName("QUERY_READER");
        roleRepository.save(queryReader);

        Group ops = new Group("ops");
        ops.addRole(queryReader);
        groupRepository.save(ops);

        User bob = new User();
        bob.setEmail("bob@example.com");
        bob.setFullName("Bob Example");
        bob.setPassword(passwordEncoder.encode("s3cret"));
        bob.setEnabled(true);
        bob.setActive(true);
        bob.setLdap(false);
        // Intentionally NO direct role — bob's only path to a role
        // is through the "ops" group.
        userRepository.save(bob);

        ops.addUser(bob);
        groupRepository.save(ops);
    }

    @Test
    void loginJwtIncludesRolesGrantedOnlyViaGroup() throws Exception {
        byte[] bodyBytes = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"bob@example.com\",\"password\":\"s3cret\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class)
                .getResponseBodyContent();

        JsonNode body = mapper.readTree(bodyBytes);
        String token = body.get("token").asText();
        assertThat(token).isNotBlank();

        String[] parts = token.split("\\.");
        assertThat(parts).hasSize(3);
        String payloadJson = new String(java.util.Base64.getUrlDecoder()
                .decode(parts[1]), StandardCharsets.UTF_8);
        JsonNode claims = mapper.readTree(payloadJson);

        java.util.List<String> roles = new java.util.ArrayList<>();
        claims.get("roles").forEach(r -> roles.add(r.asText()));
        assertThat(roles).contains("QUERY_READER");
    }
}
