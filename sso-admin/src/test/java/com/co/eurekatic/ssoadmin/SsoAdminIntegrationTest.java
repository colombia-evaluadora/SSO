package com.co.eurekatic.ssoadmin;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.entity.Endpoint;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.EndpointRepository;
import com.co.eurekatic.common.repository.GroupRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.QueryRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.RouteRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.repository.WriteDefinitionRepository;
import com.co.eurekatic.common.security.JwtTokenService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.FilterChainProxy;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.reactive.server.EntityExchangeResult;
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
import static org.mockito.Mockito.doNothing;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;

/**
 * End-to-end integration test for the sso-admin module.
 *
 * <p>Boots the full Spring context with an in-memory H2 database
 * (PostgreSQL compatibility mode + NON_KEYWORDS=GROUPS so the
 * {@code groups} table can be created), exchanges real HTTP
 * requests through a {@link WebTestClient} bound to the
 * application's {@link WebApplicationContext}, and asserts the
 * security rules, the activation flow, and the role binding
 * round-trip.
 *
 * <p><b>Why WebTestClient and not TestRestTemplate:</b>
 * Spring Boot 4.0 removed {@code TestRestTemplate} (replaced by
 * {@code RestTestClient}). We sidestep that whole migration by
 * binding the {@code WebTestClient} directly to the servlet
 * context via {@link MockMvcWebTestClient}. This also keeps the
 * Spring Security filter chain in the loop — without
 * {@code springSecurity()} the security rules are silently
 * bypassed and the {@code /getUsers} test below would return
 * 200 instead of 401/403.
 *
 * <p><b>Why we consume JSON manually:</b> the servlet-mode
 * {@code WebTestClient} does not auto-install Jackson codecs,
 * so {@code .expectBody(JsonNode.class)} fails with a
 * "Type definition error". We consume the body as
 * {@code byte[]} and parse with the {@link ObjectMapper} bean
 * — same pattern the legacy {@code TestRestTemplate} code used.
 *
 * <p>The {@link com.co.eurekatic.ssoadmin.service.EmailService}
 * bean is replaced with a mock — we don't want SMTP in tests.
 */
@SpringBootTest(
        classes = SsoAdminApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(properties = {
        "spring.datasource.url=jdbc:h2:mem:sso-admin-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;NON_KEYWORDS=GROUPS;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false",
        "spring.mail.host=localhost",
        "spring.mail.port=2525",
        // Don't run mail health probe — the fake SMTP isn't
        // actually serving, and the indicator would push the
        // /actuator/health aggregate to 503.
        "management.health.mail.enabled=false",
        // Same for RabbitMQ — no broker running in this test
        // (NotificationEventPublisher is mocked above, but the
        // RabbitHealthIndicator talks to the ConnectionFactory
        // bean directly, bypassing the mock).
        "management.health.rabbit.enabled=false"
})
class SsoAdminIntegrationTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterChainProxy springSecurityFilterChain;
    @Autowired UserRepository userRepository;
    @Autowired RoleRepository roleRepository;
    @Autowired AppRepository appRepository;
    @Autowired GroupRepository groupRepository;
    @Autowired MicroserviceRepository microserviceRepository;
    @Autowired EndpointRepository endpointRepository;
    @Autowired RouteRepository routeRepository;
    @Autowired QueryRepository queryRepository;
    @Autowired WriteDefinitionRepository writeDefinitionRepository;
    @Autowired JdbcTemplate jdbcTemplate;
    @Autowired PasswordEncoder passwordEncoder;
    @Autowired JwtTokenService jwtService;
    @Autowired ObjectMapper mapper;

    private WebTestClient client;

    // Don't hit SMTP in tests. @MockitoBean replaces the legacy
    // @MockBean annotation (Spring Framework 7 / Boot 4 moved
    // it to spring-test's bean.override.mockito package).
    @MockitoBean
    com.co.eurekatic.ssoadmin.service.EmailService emailServiceMock;

    // Don't hit RabbitMQ in tests. Wire-2 wiring routes account /
    // password flows through NotificationEventPublisher instead
    // of EmailService — the mock receives publish() calls instead.
    @MockitoBean
    com.co.eurekatic.ssoadmin.event.NotificationEventPublisher notificationPublisherMock;

    @BeforeEach
    void setUp() {
        // Bind a WebTestClient directly to the servlet
        // application context with the springSecurity()
        // configurer so the security filter chain is honored
        // (otherwise every request would bypass auth and the
        // FORBIDDEN assertion in protectedEndpointRejects*
        // would fail). MockMvcWebTestClient is servlet-based,
        // no real HTTP server needed.
        client = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(springSecurity(springSecurityFilterChain))
                .build();

        // Order matters: child tables before parents so FK
        // constraints don't trip on the H2 re-init. Catalog
        // join tables (role_query, role_write) reference role
        // and must be cleared first via a native query —
        // JPA repository.deleteAll() doesn't traverse the
        // join-table rows.
        jdbcTemplate.execute("DELETE FROM role_query");
        jdbcTemplate.execute("DELETE FROM role_write");
        jdbcTemplate.execute("DELETE FROM role_app");
        jdbcTemplate.execute("DELETE FROM app_route");
        jdbcTemplate.execute("DELETE FROM app_microservice");
        jdbcTemplate.execute("DELETE FROM app_users");
        jdbcTemplate.execute("DELETE FROM role_endpoint");
        queryRepository.deleteAll();
        writeDefinitionRepository.deleteAll();
        routeRepository.deleteAll();
        endpointRepository.deleteAll();
        microserviceRepository.deleteAll();
        appRepository.deleteAll();
        userRepository.deleteAll();
        roleRepository.deleteAll();
        groupRepository.deleteAll();

        Role admin = new Role("ADMIN", "Administrator");
        roleRepository.save(admin);

        User root = new User();
        root.setEmail("root@example.com");
        root.setFullName("Root Admin");
        root.setPassword(passwordEncoder.encode("r00t"));
        root.setEnabled(true);
        root.setActive(true);
        root.addRole(admin);
        userRepository.save(root);

        // Seed the SSO-ADMIN app and bind the ADMIN role to it.
        // SsoAdminAppAccessManager enforces role_app binding on every
        // request — without this, all authenticated requests get 403.
        App ssoAdminApp = new App();
        ssoAdminApp.setName("SSO-ADMIN");
        ssoAdminApp.setDescription("SSO Admin Console");
        ssoAdminApp.addRole(admin);
        appRepository.save(ssoAdminApp);

        // Flyway never runs against this test's H2 database (see
        // adminRoleAlsoRequiresRoleEndpointBinding's Javadoc), so
        // without this, every business CRUD test below would 403
        // under the fail-closed SsoAdminAccessManager — role_app
        // alone is no longer sufficient. Mirrors the V15 migration's
        // catalog + "ADMIN gets everything" grant so ADMIN's access
        // here matches the real deployment out of the box.
        seedAllEndpointsForAdmin();

        // Default no-op so the mock doesn't blow up.
        doNothing().when(emailServiceMock).sendActivationEmail(any(), any());
        doNothing().when(emailServiceMock).sendRestorePasswordEmail(any(), any());
    }

    /**
     * Mirrors the V15 migration's endpoint catalog and its
     * "ADMIN gets every endpoint" grant (see V15's own header
     * comment) — kept in sync by hand since this test's H2
     * database never runs Flyway.
     */
    private void seedAllEndpointsForAdmin() {
        String[][] endpoints = {
            {"POST", "/app/save"},
            {"PUT", "/app/update"},
            {"GET", "/app/getApps"},
            {"GET", "/app/{id}"},
            {"DELETE", "/app/{id}"},
            {"POST", "/app/{id}/role/{roleId}"},
            {"DELETE", "/app/{id}/role/{roleId}"},
            {"GET", "/app/{id}/roles/checked"},
            {"POST", "/app/{id}/user/{userId}"},
            {"DELETE", "/app/{id}/user/{userId}"},
            {"GET", "/app/{id}/users/checked"},
            {"POST", "/app/{id}/route/{routeId}"},
            {"DELETE", "/app/{id}/route/{routeId}"},
            {"GET", "/app/{id}/routes/checked"},
            {"POST", "/app/{id}/microservice/{microserviceId}"},
            {"DELETE", "/app/{id}/microservice/{microserviceId}"},
            {"GET", "/app/{id}/microservices/checked"},
            {"POST", "/endpoint/save"},
            {"PUT", "/endpoint/update"},
            {"GET", "/endpoint/getEndpoints"},
            {"GET", "/endpoint/{id}"},
            {"DELETE", "/endpoint/{id}"},
            {"POST", "/endpoint/{id}/microservice/{microserviceId}"},
            {"DELETE", "/endpoint/{id}/microservice/{microserviceId}"},
            {"GET", "/endpoint/{id}/microservices/checked"},
            {"POST", "/endpoint/{id}/role/{roleId}"},
            {"DELETE", "/endpoint/{id}/role/{roleId}"},
            {"GET", "/endpoint/{id}/roles/checked"},
            {"GET", "/endpoint/bySignature"},
            {"POST", "/group"},
            {"PUT", "/group/update"},
            {"GET", "/group"},
            {"POST", "/group/bindUserGroup"},
            {"POST", "/group/{id}/role/{roleId}"},
            {"DELETE", "/group/{id}/role/{roleId}"},
            {"GET", "/group/{id}/roles/checked"},
            {"POST", "/microservice/save"},
            {"POST", "/microservice/testConnection"},
            {"PUT", "/microservice/update"},
            {"GET", "/microservice/getMicroservices"},
            {"GET", "/microservice/getMicroservice"},
            {"GET", "/microservice/{id}"},
            {"DELETE", "/microservice/{id}"},
            {"GET", "/microservice/{id}/container/status"},
            {"GET", "/microservice/{id}/container/logs"},
            {"POST", "/microservice/{id}/container/restart"},
            {"GET", "/myMenu"},
            {"POST", "/query/save"},
            {"PUT", "/query/update"},
            {"GET", "/query/getQueries"},
            {"GET", "/query/{id}"},
            {"DELETE", "/query/{id}"},
            {"POST", "/query/{id}/role/{roleId}"},
            {"DELETE", "/query/{id}/role/{roleId}"},
            {"GET", "/query/{id}/roles/checked"},
            {"GET", "/query/byUuid"},
            {"GET", "/getQuery"},
            {"GET", "/myQueries"},
            {"POST", "/role/createRole"},
            {"PUT", "/role/updateRole"},
            {"GET", "/role/getRoles"},
            {"GET", "/role/getRolesOwn"},
            {"GET", "/role/users"},
            {"GET", "/role/users/checked"},
            {"POST", "/route/save"},
            {"PUT", "/route/update"},
            {"GET", "/route/getRoutes"},
            {"GET", "/route/getRoutesByParent"},
            {"GET", "/route/{id}"},
            {"DELETE", "/route/{id}"},
            {"POST", "/route/{id}/role/{roleId}"},
            {"DELETE", "/route/{id}/role/{roleId}"},
            {"GET", "/route/{id}/roles/checked"},
            {"POST", "/createAccount"},
            {"PUT", "/updateAccount"},
            {"POST", "/activateAccount"},
            {"GET", "/forgotPassword"},
            {"POST", "/restorePassword"},
            {"GET", "/getUsers"},
            {"POST", "/resendActivation/{id}"},
            {"POST", "/deactivateAccount/{id}"},
            {"POST", "/reactivateAccount/{id}"},
            {"GET", "/getRolesByEmail"},
            {"GET", "/user/roles"},
            {"POST", "/bindUserRole"},
            {"DELETE", "/unbindUserRole"},
            {"GET", "/getWrite"},
            {"POST", "/write/save"},
            {"PUT", "/write/update"},
            {"GET", "/write/getWrites"},
            {"GET", "/write/{id}"},
            {"DELETE", "/write/{id}"},
            {"POST", "/write/{id}/role/{roleId}"},
            {"DELETE", "/write/{id}/role/{roleId}"},
            {"GET", "/write/{id}/roles/checked"},
            {"GET", "/write/byUuid"},
            {"POST", "/login"},
            {"GET", "/getApiToken"},
            {"GET", "/getInfoUser"},
            {"GET", "/myApps"},
            {"GET", "/getUsersSSO"},
            {"POST", "/auth/refresh"},
            {"POST", "/auth/logout"},
            {"POST", "/googleLogin"},
        };
        for (String[] ep : endpoints) {
            jdbcTemplate.update(
                    "INSERT INTO endpoint (method, path, description, numberparams) VALUES (?, ?, ?, 0)",
                    ep[0], ep[1], ep[0] + " " + ep[1]);
        }
        jdbcTemplate.update(
                "INSERT INTO role_endpoint (endpoint_id, role_id) " +
                        "SELECT e.id_endpoint, r.id_role FROM endpoint e CROSS JOIN role r WHERE r.name = 'ADMIN'");
    }

    /* ====================== public endpoints ====================== */

    @Test
    void healthEndpointIsPublic() {
        client.get().uri("/actuator/health")
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(body -> assertThat(new String(body))
                        .contains("\"status\":\"UP\""));
    }

    @Test
    void protectedEndpointRejectsRequestWithoutToken() {
        // No Authorization header → SecurityConfig says
        // authenticated() or hasRole("ADMIN"), so anonymous
        // requests are rejected. MockMvc returns 403 (not
        // 401) because there's no AuthenticationEntryPoint
        // configured — Spring Security's default for
        // stateless API is the 403 path.
        client.get().uri("/getUsers")
                .exchange()
                .expectStatus().isForbidden();
    }

    /* ====================== role_endpoint scoped access ====================== */

    /**
     * End-to-end proof of the {@code role_endpoint} enforcement
     * added in {@code SsoAdminAccessManager}/{@code
     * EndpointAccessService}: a non-ADMIN role with {@code role_app}
     * to SSO-ADMIN but no {@code role_endpoint} bindings gets 403
     * on every business endpoint; binding it to exactly one
     * endpoint opens ONLY that one, leaving everything else 403.
     */
    @Test
    void nonAdminRoleGetsScopedAccessViaRoleEndpoint() {
        Role support = new Role("SOPORTE", "Soporte");
        roleRepository.save(support);

        User supportUser = new User();
        supportUser.setEmail("soporte@example.com");
        supportUser.setFullName("Soporte User");
        supportUser.setPassword(passwordEncoder.encode("s0p0rte"));
        supportUser.setEnabled(true);
        supportUser.setActive(true);
        supportUser.addRole(support);
        userRepository.save(supportUser);

        // role_app to SSO-ADMIN — necessary, but (per the new model)
        // no longer sufficient on its own for a non-ADMIN role.
        // setUp() already seeded the SSO-ADMIN app (bound to ADMIN);
        // reuse that row rather than inserting a second one with the
        // same unique `name`. Bind via a native insert, not
        // `app.addRole(support)` — `App.roles` is a LAZY collection
        // and the entity returned by findByName() is detached by
        // the time we'd mutate it (each repository call is its own
        // transaction), so touching the collection here throws
        // LazyInitializationException.
        Long ssoAdminAppId = appRepository.findByName("SSO-ADMIN").orElseThrow().getId();
        jdbcTemplate.update("INSERT INTO role_app (id_app, id_role) VALUES (?, ?)",
                ssoAdminAppId, support.getId());

        String token = tokenFor("soporte@example.com", "SOPORTE");

        // No role_endpoint yet -> 403 on any business endpoint.
        client.get().uri("/getUsers")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isForbidden();

        // Bind SOPORTE -> GET /getUsers specifically.
        Endpoint endpoint = new Endpoint();
        endpoint.setMethod("GET");
        endpoint.setPath("/getUsers");
        endpoint.setDescription("Listar usuarios");
        endpoint.setNumberParams(0);
        endpoint.addRole(support);
        endpointRepository.save(endpoint);

        // Now /getUsers works...
        client.get().uri("/getUsers")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk();

        // ...but a DIFFERENT endpoint, never bound, still 403s.
        client.put().uri("/updateAccount")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("id", 1, "fullName", "X"))
                .exchange()
                .expectStatus().isForbidden();
    }

    /**
     * ADMIN has NO bypass on {@code role_endpoint} — a deliberate
     * choice (see {@code SsoAdminAccessManager}'s Javadoc) so the
     * per-endpoint toggle on the Endpoints admin screen never
     * silently no-ops for ADMIN. setUp() seeds ADMIN with the full
     * V15-equivalent catalog (see {@code seedAllEndpointsForAdmin})
     * so the other business tests don't all need their own binding;
     * this test wipes that grant back to empty first so it can prove
     * the underlying rule in isolation, same as it did back when
     * setUp() left role_endpoint empty by default.
     */
    @Test
    void adminRoleAlsoRequiresRoleEndpointBinding() {
        Role admin = roleRepository.findByName("ADMIN").orElseThrow();

        jdbcTemplate.execute("DELETE FROM role_endpoint");
        endpointRepository.deleteAll();

        String token = tokenFor("root@example.com", "ADMIN");

        // role_app alone isn't enough for ADMIN either, same as
        // any other role.
        client.get().uri("/getUsers")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isForbidden();

        Endpoint endpoint = new Endpoint();
        endpoint.setMethod("GET");
        endpoint.setPath("/getUsers");
        endpoint.setDescription("Listar usuarios");
        endpoint.setNumberParams(0);
        endpoint.addRole(admin);
        endpointRepository.save(endpoint);

        client.get().uri("/getUsers")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk();

        // A different, unbound endpoint still 403s ADMIN too.
        client.put().uri("/updateAccount")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(Map.of("id", 1, "fullName", "X"))
                .exchange()
                .expectStatus().isForbidden();
    }

    /* ====================== auth-gated CRUD ====================== */

    @Test
    void getUsersReturnsSeededAdmin() {
        String token = tokenFor("root@example.com", "ADMIN");

        client.get().uri("/getUsers")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr.isArray()).isTrue();
                    assertThat(arr).hasSize(1);
                    // UserResponse no longer carries `username` since
                    // the V12 migration (email IS the login identifier).
                    assertThat(arr.get(0).get("email").asText()).isEqualTo("root@example.com");
                    assertThat(arr.get(0).get("fullName").asText()).isEqualTo("Root Admin");
                    // The password is NEVER exposed in the response.
                    assertThat(arr.get(0).has("password")).isFalse();
                }));
    }

    @Test
    void createAccountPersistsUserWithDisabledFlagAndSendsEmail() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        // Admin no longer types a password on create — the user
        // sets one by clicking the activation link. The wire body
        // (post-V12) is {fullName, email, roleNames} — username is
        // gone since email IS the login identifier.
        String body = mapper.writeValueAsString(Map.of(
                "fullName", "Alice Example",
                "email", "alice@example.com",
                "roleNames", List.of("ADMIN")
        ));

        client.post().uri("/createAccount")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .value(jsonBody(json -> {
                    assertThat(json.get("email").asText()).isEqualTo("alice@example.com");
                    assertThat(json.get("active").asBoolean()).isTrue();
                    assertThat(json.get("ldap").asBoolean()).isFalse();
                }));

        User stored = userRepository.findByEmail("alice@example.com").orElseThrow();
        // Until the activation link is clicked, the user cannot log in.
        assertThat(stored.isEnabled()).isFalse();
        assertThat(stored.getTokenActivation()).isNotBlank();
        // No password yet — the user sets one at /activateAccount.
        assertThat(stored.getPassword()).isNull();

        // Wire-2: createAccount publishes the activation event via
        // NotificationEventPublisher → notification-service renders
        // and sends the email. We verify the event was published;
        // notification-service delivery is covered by its own
        // Testcontainers suite.
        org.mockito.Mockito.verify(notificationPublisherMock)
                .publish(
                        org.mockito.ArgumentMatchers.eq("email"),
                        any(),
                        org.mockito.ArgumentMatchers.eq("alice@example.com"),
                        org.mockito.ArgumentMatchers.eq("account-activation"),
                        any(),
                        any());
    }

    @Test
    void createAccountRejectsDuplicateEmailWith409() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        String body = mapper.writeValueAsString(Map.of(
                "fullName", "Another Root",
                "email", "root@example.com"
        ));

        client.post().uri("/createAccount")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isEqualTo(409)
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.get("code").asText())
                        .isEqualTo("USER_DUPLICATE")));
    }

    @Test
    void createAccountRejectsInvalidEmailWith422() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        String body = mapper.writeValueAsString(Map.of(
                "fullName", "Bad Email",
                "email", "not-an-email"
        ));

        client.post().uri("/createAccount")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isEqualTo(422);
    }

    @Test
    void activateAccountEnablesUserWithoutAuth() throws Exception {
        // First, create a user — capture the activation token via
        // the user row (tokenActivation column).
        String token = tokenFor("root@example.com", "ADMIN");
        // Wire body has NO password, NO username — admin types
        // fullName + email; the user sets the password via the
        // activation call below.
        String body = mapper.writeValueAsString(Map.of(
                "fullName", "Bob", "email", "bob@example.com"));
        client.post().uri("/createAccount")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isCreated();

        User created = userRepository.findByEmail("bob@example.com").orElseThrow();
        String activationToken = created.getTokenActivation();
        assertThat(activationToken).isNotBlank();

        // POST + JSON body. The password now travels in the body,
        // not the URL — see UserController.activateAccount for the
        // accompanying HTTP verb flip. No Authorization header
        // because the link from the email does not include one.
        String activateBody = mapper.writeValueAsString(Map.of(
                "token", activationToken,
                "password", "newpass1"));
        client.post().uri("/activateAccount")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(activateBody)
                .exchange()
                .expectStatus().isOk();

        User after = userRepository.findByEmail("bob@example.com").orElseThrow();
        assertThat(after.isEnabled()).isTrue();
        assertThat(after.isActive()).isTrue();
        // Token column cleared on use — cannot be replayed.
        assertThat(after.getTokenActivation()).isNull();
        assertThat(passwordEncoder.matches("newpass1", after.getPassword())).isTrue();
    }

    @Test
    void activateAccountWithUnknownTokenReturns404() throws Exception {
        String body = mapper.writeValueAsString(Map.of(
                "token", "does-not-exist",
                "password", "newpass1"));
        client.post().uri("/activateAccount")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isNotFound();
    }

    @Test
    void activateAccountRejectsShortPassword() throws Exception {
        // @Size(min = 6) on the TokenPasswordRequest.password field
        // turns "123" into a MethodArgumentNotValidException BEFORE
        // the service is reached, so the existing service-level
        // invariant (IllegalArgumentException → 400 INVALID_REQUEST)
        // is still defended by a higher layer. GlobalExceptionHandler
        // maps all @Valid body violations to 422 (same as
        // createAccountRejectsInvalidEmailWith422) — this pins the
        // controller-side validation contract that closed the
        // GET-with-password-in-query leak surface.
        String body = mapper.writeValueAsString(Map.of(
                "token", "anything",
                "password", "123"));
        client.post().uri("/activateAccount")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isEqualTo(422);
    }

    @Test
    void restorePasswordEnablesUserWithoutAuth() throws Exception {
        // Create a user directly via the repository (faster than going
        // through POST /createAccount which now mints an activation
        // token we don't need here), then trigger forgotPassword to
        // issue a real restore token. Wire-2: the flow now publishes
        // a NotificationMessage event (notification-service renders
        // and sends the email); the token rides in the payload's
        // resetLink query string. We extract it back out via the
        // captor.
        User u = new User();
        u.setEmail("carol@example.com");
        u.setFullName("Carol");
        u.setPassword(passwordEncoder.encode("oldpass1"));
        u.setEnabled(true);
        u.setActive(true);
        u = userRepository.save(u);

        client.get().uri(uri -> uri.path("/forgotPassword")
                        .queryParam("email", "carol@example.com")
                        .build())
                .exchange()
                .expectStatus().isOk();

        @SuppressWarnings("unchecked")
        org.mockito.ArgumentCaptor<Map<String, Object>> payload =
                org.mockito.ArgumentCaptor.forClass(Map.class);
        org.mockito.Mockito.verify(notificationPublisherMock)
                .publish(
                        org.mockito.ArgumentMatchers.eq("email"),
                        any(),
                        org.mockito.ArgumentMatchers.eq("carol@example.com"),
                        org.mockito.ArgumentMatchers.eq("password-reset"),
                        payload.capture(),
                        any());

        String restoreToken = extractToken(payload.getValue().get("resetLink").toString());
        assertThat(restoreToken).hasSize(36); // UUID format, same as TokenService

        // POST + JSON body — same shape as /activateAccount.
        String body = mapper.writeValueAsString(Map.of(
                "token", restoreToken,
                "password", "newpass1"));
        client.post().uri("/restorePassword")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isOk();

        User after = userRepository.findByEmail("carol@example.com").orElseThrow();
        // Restore does NOT touch enabled/active (only activate does),
        // but it MUST clear the restore token column to enforce
        // single-use semantics.
        assertThat(after.getTokenRestore()).isNull();
        assertThat(passwordEncoder.matches("newpass1", after.getPassword())).isTrue();
    }

    /** Pulls the {@code token=...} query string out of the
     * {@code resetLink} URL produced by UserAdminService.forgotPassword
     * when wrapping the restore token in the notification payload. */
    private static String extractToken(String url) {
        int i = url.indexOf("token=");
        if (i < 0) throw new AssertionError("resetLink missing token= : " + url);
        String tail = url.substring(i + "token=".length());
        int amp = tail.indexOf('&');
        return amp < 0 ? tail : tail.substring(0, amp);
    }

    @Test
    void restorePasswordWithUnknownTokenReturns404() throws Exception {
        String body = mapper.writeValueAsString(Map.of(
                "token", "does-not-exist",
                "password", "newpass1"));
        client.post().uri("/restorePassword")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isNotFound();
    }

    @Test
    void restorePasswordRejectsShortPassword() throws Exception {
        // Same controller-side validation contract as
        // activateAccountRejectsShortPassword — see that test for
        // the rationale. The shared TokenPasswordRequest DTO is
        // what makes this a single pin.
        String body = mapper.writeValueAsString(Map.of(
                "token", "anything",
                "password", "123"));
        client.post().uri("/restorePassword")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isEqualTo(422);
    }

    @Test
    void roleCreateAndListRoundTrip() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        client.post().uri("/role/createRole")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("name", "AUDITOR", "description", "Read only")))
                .exchange()
                .expectStatus().isCreated();

        client.get().uri("/role/getRoles")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b)
                        .hasSizeGreaterThanOrEqualTo(2))); // ADMIN + AUDITOR

        // Just make sure the endpoint shape is what the legacy UI expects.
        client.get().uri("/role/getRolesOwn")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.isArray()).isTrue()));
    }

    @Test
    void groupCreateAndList() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        client.post().uri("/group")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("name", "Ops", "description", "Operations")))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.get("name").asText())
                        .isEqualTo("Ops")));

        client.get().uri("/group")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(1);
                    assertThat(arr.get(0).get("memberCount").asInt()).isZero();
                }));
    }

    /**
     * Regression for a bug caught in review: the admin-ui edit
     * flow used to submit renames through {@code POST /group}
     * (name-keyed upsert), which created a duplicate group
     * instead of renaming the original. {@code PUT
     * /group/update} is id-keyed and must rename in place.
     */
    @Test
    void groupUpdateRenamesInPlaceById() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        byte[] created = client.post().uri("/group")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("name", "Ops", "description", "Operations")))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        long id = mapper.readTree(created).get("id").asLong();

        client.put().uri("/group/update")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("id", id, "name", "Operations", "description", "Renamed")))
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(b -> {
                    assertThat(b.get("id").asLong()).isEqualTo(id);
                    assertThat(b.get("name").asText()).isEqualTo("Operations");
                }));

        // Renamed in place — still exactly one group, under the new name.
        client.get().uri("/group")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(1);
                    assertThat(arr.get(0).get("name").asText()).isEqualTo("Operations");
                }));
    }

    @Test
    void groupUpdateRejectsRenameOntoAnotherGroupsName() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        client.post().uri("/group")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("name", "Ops", "description", "Operations")))
                .exchange()
                .expectStatus().isCreated();

        byte[] financeGroup = client.post().uri("/group")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("name", "Finance", "description", "Finance team")))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .returnResult()
                .getResponseBody();
        long financeId = mapper.readTree(financeGroup).get("id").asLong();

        // Renaming Finance to "Ops" must fail, not silently overwrite Ops.
        client.put().uri("/group/update")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("id", financeId, "name", "Ops", "description", "Finance team")))
                .exchange()
                .expectStatus().isEqualTo(409);
    }

    /* ====================== Phase 2: microservice / endpoint / route ====================== */

    @Test
    void microserviceCreateAndListRoundTrip() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        String body = mapper.writeValueAsString(Map.of(
                "serviceId", "users-svc",
                "description", "Users microservice",
                "requestUri", "/users/**",
                "targetUriPath", "/api/v1",
                "targetUrlHost", "users.internal",
                "targetUrlPort", "8080"
        ));

        client.post().uri("/microservice/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.get("serviceId").asText())
                        .isEqualTo("users-svc")));

        client.get().uri("/microservice/getMicroservices")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(1);
                    assertThat(arr.get(0).get("serviceId").asText())
                            .isEqualTo("users-svc");
                    assertThat(arr.get(0).has("password")).isFalse();
                }));
    }

    @Test
    void microserviceDuplicateServiceIdReturns409() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        String body = mapper.writeValueAsString(Map.of("serviceId", "dup"));

        client.post().uri("/microservice/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isCreated();

        client.post().uri("/microservice/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isEqualTo(409)
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.get("code").asText())
                        .isEqualTo("DUPLICATE")));
    }

    @Test
    void endpointCreateBindMicroserviceAndCheckEndpoint() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        // Create a microservice to bind to.
        EntityExchangeResult<byte[]> msResult = client.post().uri("/microservice/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(Map.of("serviceId", "users-svc")))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .returnResult();
        long microserviceId = mapper.readTree(msResult.getResponseBody()).get("id").asLong();

        // Create the endpoint.
        EntityExchangeResult<byte[]> epResult = client.post().uri("/endpoint/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(Map.of(
                        "method", "GET",
                        "path", "/api/users",
                        "description", "List users",
                        "numberParams", 0)))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .returnResult();
        long endpointId = mapper.readTree(epResult.getResponseBody()).get("id").asLong();

        // Bind the microservice.
        client.post().uri("/endpoint/" + endpointId + "/microservice/" + microserviceId)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isNoContent();

        // Verified by the checked listing.
        client.get().uri("/endpoint/" + endpointId + "/microservices/checked")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(rows -> {
                    assertThat(rows).hasSize(1);
                    assertThat(rows.get(0).get("serviceId").asText())
                            .isEqualTo("users-svc");
                    assertThat(rows.get(0).get("checked").asBoolean()).isTrue();
                }));
    }

    @Test
    void endpointDuplicatePathMethodDescriptionReturns409() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        String body = mapper.writeValueAsString(Map.of(
                "method", "GET", "path", "/dup", "description", "D", "numberParams", 0));

        client.post().uri("/endpoint/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isCreated();

        client.post().uri("/endpoint/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isEqualTo(409);
    }

    @Test
    void endpointBindRoleAndCheckedListing() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        EntityExchangeResult<byte[]> epResult = client.post().uri("/endpoint/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(Map.of(
                        "method", "POST", "path", "/x", "description", "x", "numberParams", 0)))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .returnResult();
        long endpointId = mapper.readTree(epResult.getResponseBody()).get("id").asLong();

        long adminRoleId = roleRepository.findByName("ADMIN").orElseThrow().getId();

        client.post().uri("/endpoint/" + endpointId + "/role/" + adminRoleId)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isNoContent();

        client.get().uri("/endpoint/" + endpointId + "/roles/checked")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(rows -> {
                    assertThat(rows).hasSize(1);
                    assertThat(rows.get(0).get("name").asText()).isEqualTo("ADMIN");
                    assertThat(rows.get(0).get("checked").asBoolean()).isTrue();
                }));
    }

    @Test
    void routeCreateWithLegacyZeroParentNormalizesToNull() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");
        String body = mapper.writeValueAsString(Map.of(
                "name", "Home",
                "path", "/home",
                "menuOrder", 1,
                "type", "MENU",
                "idParent", 0    // legacy "root" sentinel
        ));

        client.post().uri("/route/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.get("idParent").isNull())
                        .isTrue()));

        // /route/getRoutesByParent without an idParent should return roots only.
        client.get().uri("/route/getRoutesByParent")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(arr -> {
                    assertThat(arr).hasSize(1);
                    assertThat(arr.get(0).get("name").asText()).isEqualTo("Home");
                }));
    }

    @Test
    void routeBindRoleAndCheckedListing() throws Exception {
        String token = tokenFor("root@example.com", "ADMIN");

        EntityExchangeResult<byte[]> created = client.post().uri("/route/save")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(Map.of(
                        "name", "Settings", "path", "/settings", "menuOrder", 2)))
                .exchange()
                .expectStatus().isCreated()
                .expectBody(byte[].class)
                .returnResult();
        long routeId = mapper.readTree(created.getResponseBody()).get("id").asLong();

        long adminRoleId = roleRepository.findByName("ADMIN").orElseThrow().getId();
        client.post().uri("/route/" + routeId + "/role/" + adminRoleId)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isNoContent();

        client.get().uri("/route/" + routeId + "/roles/checked")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(rows -> {
                    assertThat(rows).hasSize(1);
                    assertThat(rows.get(0).get("name").asText()).isEqualTo("ADMIN");
                    assertThat(rows.get(0).get("checked").asBoolean()).isTrue();
                }));
    }

    /* ====================== Phase 3: query/write catalog endpoints ====================== */

    /**
     * The catalog endpoints (/getQuery, /getWrite) accept ANY
     * authenticated caller — the per-row permission check
     * happens inside the catalog service. We seed a Query
     * bound to ADMIN, a Query with publicEnd=true, and a Query
     * bound to a non-admin role, then probe all three from a
     * caller that has only USER (not ADMIN).
     */
    @Test
    void getQueryEndpointRequiresRoleBindingUnlessPublic() throws Exception {
        com.co.eurekatic.common.entity.Query adminOnly =
                seedQuery("q-admin", "SELECT 1", false, "ADMIN");
        com.co.eurekatic.common.entity.Query publicQ =
                seedQuery("q-public", "SELECT 2", true, "ANALYST");
        com.co.eurekatic.common.entity.Query analystOnly =
                seedQuery("q-analyst", "SELECT 3", false, "ANALYST");

        // Caller "alice" has USER only — none of the bound
        // roles for any of the seeded queries.
        String userToken = tokenFor("alice@example.com", "USER");

        // Bound to ADMIN, alice is not ADMIN → 403.
        client.get().uri(uri -> uri.path("/getQuery")
                        .queryParam("uuid", adminOnly.getUuid()).build())
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + userToken)
                .exchange()
                .expectStatus().isForbidden();

        // publicEnd=true → caller gets it regardless of role.
        client.get().uri(uri -> uri.path("/getQuery")
                        .queryParam("uuid", publicQ.getUuid()).build())
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + userToken)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(b -> assertThat(b.get("uuid").asText())
                        .isEqualTo(publicQ.getUuid())));

        // Bound to ANALYST, alice is not ANALYST → 403. The
        // "missing vs forbidden" indistinguishability is by
        // design — verify it also returns 403 (not 404).
        client.get().uri(uri -> uri.path("/getQuery")
                        .queryParam("uuid", analystOnly.getUuid()).build())
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + userToken)
                .exchange()
                .expectStatus().isForbidden();
    }

    /**
     * The /getQuery endpoint requires authentication (a valid
     * bearer token); without it the SecurityConfig
     * {@code .authenticated()} rule rejects the request.
     */
    @Test
    void getQueryRejectsAnonymous() {
        client.get().uri("/getQuery?uuid=does-not-matter")
                .exchange()
                .expectStatus().isForbidden();
    }

    /**
     * Same shape as {@link #getQueryEndpointRequiresRoleBindingUnlessPublic}
     * but for /getWrite. Writes are never public, so the only
     * positive case is "caller has a bound role".
     */
    @Test
    void getWriteEndpointRequiresRoleBinding() throws Exception {
        com.co.eurekatic.common.entity.WriteDefinition wd =
                seedWriteDefinition("wd-admin", com.co.eurekatic.common.entity.WriteType.INSERT,
                        "users", "[\"id\",\"name\"]", "[\"id\"]", "ADMIN");

        // Alice has USER — not ADMIN — so the role check
        // inside WriteCatalogService must reject her.
        String userToken = tokenFor("alice@example.com", "USER");
        client.get().uri(uri -> uri.path("/getWrite")
                        .queryParam("uuid", wd.getUuid()).build())
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + userToken)
                .exchange()
                .expectStatus().isForbidden();

        // Root has ADMIN — the bound role matches.
        String adminToken = tokenFor("root@example.com", "ADMIN");
        client.get().uri(uri -> uri.path("/getWrite")
                        .queryParam("uuid", wd.getUuid()).build())
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                .exchange()
                .expectStatus().isOk()
                .expectBody(byte[].class)
                .value(jsonBody(b -> {
                    assertThat(b.get("uuid").asText()).isEqualTo(wd.getUuid());
                    assertThat(b.get("tableName").asText()).isEqualTo("users");
                    assertThat(b.get("columns").isArray()).isTrue();
                    assertThat(b.get("keyColumns").isArray()).isTrue();
                }));
    }

    /* ====================== helpers ====================== */

    private String tokenFor(String username, String... roles) {
        Set<String> roleSet = new LinkedHashSet<>(List.of(roles));
        return jwtService.issueAccessToken(username, roleSet);
    }

    /**
     * Persists a {@link com.co.eurekatic.common.entity.Query}
     * with one role binding. Returns the saved entity (with
     * its generated UUID).
     */
    private com.co.eurekatic.common.entity.Query seedQuery(
            String uuid, String sql, boolean publicEnd, String roleName) {
        Role role = roleRepository.findByName(roleName).orElseGet(() -> {
            Role r = new Role(roleName, roleName);
            roleRepository.save(r);
            return r;
        });
        com.co.eurekatic.common.entity.Query q = new com.co.eurekatic.common.entity.Query();
        q.setUuid(uuid);
        q.setQuery(sql);
        q.setType("SQL");
        q.setPublicEnd(publicEnd);
        q.setCaptcha(false);
        q.addRole(role);
        return queryRepository.save(q);
    }

    /**
     * Persists a {@link com.co.eurekatic.common.entity.WriteDefinition}
     * with one role binding. Returns the saved entity.
     */
    private com.co.eurekatic.common.entity.WriteDefinition seedWriteDefinition(
            String uuid,
            com.co.eurekatic.common.entity.WriteType type,
            String tableName,
            String columnsJson,
            String keyColumnsJson,
            String roleName) {
        Role role = roleRepository.findByName(roleName).orElseGet(() -> {
            Role r = new Role(roleName, roleName);
            roleRepository.save(r);
            return r;
        });
        com.co.eurekatic.common.entity.WriteDefinition w = new com.co.eurekatic.common.entity.WriteDefinition();
        w.setUuid(uuid);
        w.setWriteType(type);
        w.setTableName(tableName);
        w.setColumns(columnsJson);
        w.setKeyColumns(keyColumnsJson);
        w.addRole(role);
        return writeDefinitionRepository.save(w);
    }

    /**
     * Parses the response body bytes as JSON and feeds the
     * resulting {@link JsonNode} to {@code assertion}. Wraps
     * any {@link java.io.IOException} thrown by Jackson as an
     * unchecked exception so the lambda body stays a clean
     * {@code Consumer<byte[]>} (WebTestClient lambdas can't
     * throw checked exceptions).
     */
    private Consumer<byte[]> jsonBody(Consumer<JsonNode> assertion) {
        return body -> {
            try {
                assertion.accept(mapper.readTree(body));
            } catch (java.io.IOException e) {
                throw new RuntimeException("Failed to parse response JSON", e);
            }
        };
    }

    @SuppressWarnings("unused") // referenced from Javadoc only
    private static final Consumer<JsonNode> TYPE_KEEP = n -> {};
}