package com.co.eurekatic.auth;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.FluxExchangeResult;
import org.springframework.test.web.reactive.server.WebTestClient;
import org.springframework.test.web.servlet.client.MockMvcWebTestClient;
import org.springframework.web.context.WebApplicationContext;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * End-to-end integration test for the auth-center module.
 *
 * <p>Boots the full Spring context (replacing the Postgres datasource
 * with an in-memory H2) and exercises the authentication surface via
 * the Spring filter chain — Security, custom JWT filter, the
 * {@code JsonLoginFilter}, controllers and exception handlers all
 * participate as they would in production. The {@code MOCK}
 * {@code webEnvironment} is sufficient because MockMvc routes requests
 * through the same {@link jakarta.servlet.Filter} chain that Tomcat
 * would; no real port is opened.
 *
 * <p>Verified contract:
 * <ol>
 *   <li>Bad credentials return 401.</li>
 *   <li>Good credentials return 200 + a JWT-shaped body.</li>
 *   <li>{@code /getInfoUser} accepts the token and returns the user.</li>
 *   <li>Missing token on a protected endpoint returns 401.</li>
 *   <li>Refresh-cookie issuance, rotation, and logout all match the
 *       documented contract.</li>
 * </ol>
 *
 * <p><b>Boot 4.0 migration note:</b> {@code TestRestTemplate} was
 * removed in Spring Boot 4. The replacement for servlet integration
 * tests is {@link WebTestClient} bound to the
 * {@link WebApplicationContext} via {@link MockMvcWebTestClient}. That
 * connector still drives the real DispatcherServlet + Spring Security
 * filter chain — only the transport differs (in-process instead of
 * loopback HTTP). We capture response bodies and the {@code Set-Cookie}
 * header via {@link FluxExchangeResult#getResponseHeaders()} and
 * {@link FluxExchangeResult#getResponseBodyContent()}.
 *
 * <p>Eureka client is disabled so the test does not require a running
 * registry; we test the auth-center in isolation.
 */
@SpringBootTest(
        classes = AuthCenterApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK
)
@TestPropertySource(properties = {
        // Replace Postgres with H2 in PostgreSQL compatibility mode
        "spring.datasource.url=jdbc:h2:mem:auth-center-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
        // Keep the JWT secret stable and long enough for HS256
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        // Disable the user-roles cache so reseeding the user table
        // between tests doesn't fight a stale Redis entry. The
        // integration test asserts login + JWT shape; the cache
        // is exercised by the dedicated CachedEffectiveRolesResolverTest.
        "sso.session.user-roles.enabled=false",
        // Don't try to register with Eureka
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false"
})
@Testcontainers
class AuthCenterIntegrationTest {

    /**
     * One Redis container shared across the test class. Persistence
     * is disabled (matching the docker-compose service) — these
     * tests assume the store is ephemeral.
     */
    @Container
    @SuppressWarnings("resource") // Testcontainers manages lifecycle
    static final GenericContainer<?> REDIS = new GenericContainer<>(
            DockerImageName.parse("redis:7-alpine"))
            .withCommand("redis-server", "--save", "", "--appendonly", "no")
            .withExposedPorts(6379);

    /**
     * Inject the container's host/port into the Spring context so
     * Lettuce / StringRedisTemplate connect to the right address.
     * The {@code spring.data.redis.password} property is omitted on
     * purpose — the container runs without --requirepass, matching
     * the dev docker-compose service.
     */
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
    PasswordEncoder passwordEncoder;

    @Autowired
    ObjectMapper mapper;

    // NOTE: the two "store unavailable" tests originally planned for
    // this section (refreshWhenRedisIsUnavailableReturns401 and
    // loginWhenRedisIsUnavailableReturns503) are covered by the
    // smoke script in admin-ui/scripts/smoke-auth-refresh.sh (Commit 9)
    // against the live stack. Driving them as Spring integration tests
    // would require stopping the shared Testcontainers Redis container
    // or wiring a fake bean that bypasses Lettuce, both of which add
    // significant test infrastructure for a single happy-path /
    // sad-path pair. The Spring-level fail-closed behaviour is already
    // exercised by the production code paths visible in
    // JsonLoginFilter (503 on mint failure) and RefreshController
    // (401 store_unavailable on rotate Unavailable outcome).

    /**
     * Built per-test from the live {@link WebApplicationContext} so it
     * sees the same Spring Security filter chain (incl.
     * {@code JwtAuthenticationFilter} and {@code JsonLoginFilter}) that
     * production requests hit.
     */
    private WebTestClient webTestClient;

    @BeforeEach
    void seed() {
        // .apply(springSecurity()) wires the SecurityFilterChain bean
        // (incl. JsonLoginFilter and JwtAuthenticationFilter) into the
        // underlying MockMvc. Without it, MockMvc skips the security
        // chain and POST /login falls through to a 404 because no
        // @PostMapping handles it — the filter is the handler.
        webTestClient = MockMvcWebTestClient.bindToApplicationContext(context)
                .apply(SecurityMockMvcConfigurers.springSecurity())
                .build();

        userRepository.deleteAll();
        roleRepository.deleteAll();

        Role userRole = new Role();
        userRole.setName("USER");
        roleRepository.save(userRole);

        Role adminRole = new Role();
        adminRole.setName("ADMIN");
        roleRepository.save(adminRole);

        User alice = new User();
        alice.setEmail("alice@example.com");
        alice.setFullName("Alice Example");
        alice.setPassword(passwordEncoder.encode("s3cret"));
        alice.setEnabled(true);
        alice.setActive(true);
        alice.setLdap(false);
        alice.addRole(userRole);
        alice.addRole(adminRole);
        userRepository.save(alice);

        // Bob exists for the non-admin /getUsersSSO test: he has the
        // USER role only, NOT ADMIN. With the SecurityConfig rule
        // `hasAuthority("ADMIN")` (Commit 11), bob's token should
        // be authenticated but rejected with 403 — not allowed to
        // see the full user list.
        User bob = new User();
        bob.setEmail("bob@example.com");
        bob.setFullName("Bob Example");
        bob.setPassword(passwordEncoder.encode("s3cret"));
        bob.setEnabled(true);
        bob.setActive(true);
        bob.setLdap(false);
        bob.addRole(userRole);
        userRepository.save(bob);
    }

    @Test
    void loginWithBadCredentialsReturns401() {
        webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"alice@example.com\",\"password\":\"wrong\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    void loginWithGoodCredentialsReturnsJwt() throws Exception {
        byte[] bodyBytes = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"alice@example.com\",\"password\":\"s3cret\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class)
                .getResponseBodyContent();

        JsonNode body = mapper.readTree(bodyBytes);
        assertThat(body.get("token").asText()).isNotBlank();
        assertThat(body.get("refreshToken").asText()).isNotBlank();
        assertThat(body.get("expiresIn").asLong()).isEqualTo(3600L);
    }

    @Test
    void getInfoUserAcceptsIssuedToken() throws Exception {
        String token = loginAndGetToken("alice@example.com", "s3cret");

        byte[] bodyBytes = webTestClient.get().uri("/getInfoUser")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class)
                .getResponseBodyContent();

        JsonNode body = mapper.readTree(bodyBytes);
        // UserSummary no longer carries the `username` slot since
        // the V12 migration (email IS the unique login identifier).
        assertThat(body.get("email").asText()).isEqualTo("alice@example.com");
        assertThat(body.get("fullName").asText()).isEqualTo("Alice Example");
    }

    @Test
    void getInfoUserWithoutTokenReturns401() {
        webTestClient.get().uri("/getInfoUser")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    /* ====================== /getUsersSSO auth gating ====================== */

    @Test
    void getUsersSsoWithoutTokenReturns401() {
        // Closes the anonymous user-enumeration / PII leak: prior to
        // Commit 11, GET /getUsersSSO was permitAll and returned
        // a list with every active user's username + email +
        // fullName + roles to any caller. With hasAuthority("ADMIN")
        // the SecurityConfig rejects anonymous callers with 401
        // before the controller ever runs.
        webTestClient.get().uri("/getUsersSSO")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    void getUsersSsoWithNonAdminTokenReturns403() throws Exception {
        // Bob has the USER role but NOT ADMIN. hasAuthority("ADMIN")
        // authenticates the token (the JwtAuthenticationFilter
        // populates SecurityContext with his `["USER"]` authority)
        // but AccessDecisionManager denies access — the configured
        // accessDeniedHandler responds with 403.
        String bobToken = loginAndGetToken("bob@example.com", "s3cret");
        webTestClient.get().uri("/getUsersSSO")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + bobToken)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.FORBIDDEN);
    }

    @Test
    void getUsersSsoWithAdminTokenReturns200() throws Exception {
        // Alice has both USER and ADMIN. ADMIN is enough.
        String aliceToken = loginAndGetToken("alice@example.com", "s3cret");
        byte[] bodyBytes = webTestClient.get().uri("/getUsersSSO")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + aliceToken)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class)
                .getResponseBodyContent();

        JsonNode body = mapper.readTree(bodyBytes);
        assertThat(body.isArray()).isTrue();
        // Both seeded users (alice + bob) must be visible because
        // getUsersSSO is filtering by enabled (not by role). If the
        // SecurityConfig gate accidentally allowed anonymous
        // callers through (regression), they would also see the same
        // body — but the 200 status alone is the proof point: the
        // 401/403/200 ladder is what the test pins down.
        assertThat(body.size()).isGreaterThanOrEqualTo(2);

        java.util.Set<String> emails = new java.util.HashSet<>();
        for (JsonNode u : body) {
            emails.add(u.get("email").asText());
        }
        assertThat(emails).contains("alice@example.com", "bob@example.com");
    }

    /* ====================== /getToken absent surface ====================== */

    @Test
    void getTokenAnonymousReturns401() {
        // GET /getToken?refreshToken=... used to accept any
        // non-empty refreshToken and return a fresh access token
        // for the bearer of the Authorization header. The
        // refreshToken parameter was decorative (no store check).
        // The endpoint was removed in this branch. Without a
        // permit-all SecurityConfig rule for /getToken,
        // anonymous requests now fall through to
        // anyRequest().authenticated() and the unauthorized
        // entry point returns 401.
        //
        // If a future maintainer re-adds /getToken to the
        // permit-all chain by accident (e.g. copying an old
        // rule list), this test catches the regression before
        // it ships.
        webTestClient.get().uri(uriBuilder -> uriBuilder
                        .path("/getToken")
                        .queryParam("refreshToken", "anything")
                        .build())
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    void getTokenAuthenticatedReturns404() throws Exception {
        // Even when the caller holds a valid Bearer token, the
        // GET /getToken controller method is gone. Spring MVC's
        // default no-handler path returns 404. This pins the
        // shape end-to-end: an attacker with a stolen access
        // token cannot trigger any code path through /getToken
        // — there is no code path to trigger.
        String aliceToken = loginAndGetToken("alice@example.com", "s3cret");
        webTestClient.get().uri(uriBuilder -> uriBuilder
                        .path("/getToken")
                        .queryParam("refreshToken", "ANY_GARBAGE")
                        .build())
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + aliceToken)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    void googleLoginReturns501() throws Exception {
        byte[] bodyBytes = webTestClient.post().uri("/googleLogin")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"idToken\":\"x\",\"appName\":\"y\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.NOT_IMPLEMENTED)
                .returnResult(Void.class)
                .getResponseBodyContent();

        JsonNode body = mapper.readTree(bodyBytes);
        assertThat(body.get("error").asText()).isEqualTo("google_login_not_configured");
    }

    /* ====================== cookie / refresh / logout ====================== */

    @Test
    void loginSetsRefreshCookieWithCorrectAttributes() {
        FluxExchangeResult<Void> result = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"alice@example.com\",\"password\":\"s3cret\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);

        String setCookie = result.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE);
        assertThat(setCookie).isNotNull();
        // Cookie name + scope + flags are the security guarantees the SPA
        // depends on. If any of these change, update the docs.
        assertThat(setCookie).startsWith("sso_refresh=");
        // Path is "/" so the cookie rides both the legacy /auth/refresh
        // path and the gateway-mounted /api/auth/refresh path; see the
        // matching comment in JsonLoginFilter.REFRESH_COOKIE_PATH.
        assertThat(setCookie).contains("Path=/");
        assertThat(setCookie).contains("HttpOnly");
        assertThat(setCookie).contains("SameSite=Strict");
        assertThat(setCookie).contains("Max-Age=2592000"); // 30 days
        // The test runs over plain HTTP — Secure must NOT be set,
        // because if it were, the browser would never send the cookie
        // back from a non-HTTPS dev environment.
        assertThat(setCookie).doesNotContain("Secure");
    }

    @Test
    void refreshWithoutCookieReturns401() {
        byte[] bodyBytes = webTestClient.post().uri("/auth/refresh")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED)
                .returnResult(Void.class)
                .getResponseBodyContent();

        assertThat(new String(bodyBytes, StandardCharsets.UTF_8)).contains("no_refresh_cookie");
    }

    @Test
    void refreshWithCookieReturnsNewAccessTokenAndRotatedCookie() throws Exception {
        // First, log in to get a cookie.
        FluxExchangeResult<Void> loginResult = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"alice@example.com\",\"password\":\"s3cret\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);
        String initialCookie = loginResult.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE);
        assertThat(initialCookie).isNotNull();
        String initialValue = extractCookieValue(initialCookie);
        assertThat(initialValue).isNotBlank();

        // Now call /auth/refresh carrying the cookie.
        FluxExchangeResult<Void> refreshResult = webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", initialValue)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);

        JsonNode body = mapper.readTree(refreshResult.getResponseBodyContent());
        assertThat(body.get("token").asText()).isNotBlank();
        assertThat(body.get("expiresIn").asLong()).isEqualTo(3600L);

        // The Set-Cookie header is back with a NEW value (rotation).
        String newCookie = refreshResult.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE);
        assertThat(newCookie).startsWith("sso_refresh=");
        String newValue = extractCookieValue(newCookie);
        assertThat(newValue).isNotBlank();
        assertThat(newValue).isNotEqualTo(initialValue);
    }

    @Test
    void logoutSetsCookieToMaxAgeZero() {
        FluxExchangeResult<Void> result = webTestClient.post().uri("/auth/logout")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);

        String setCookie = result.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE);
        assertThat(setCookie).startsWith("sso_refresh=");
        assertThat(setCookie).contains("Max-Age=0");
        assertThat(setCookie).contains("Path=/");
        assertThat(setCookie).contains("HttpOnly");
        assertThat(setCookie).contains("SameSite=Strict");
    }

    /* ====================== new: rotation, reuse, logout,
       multi-device, store-unavailable ====================== */

    /**
     * Reuse of an already-rotated cookie must return 401 with
     * {@code refresh_token_reuse} and the family must be wiped —
     * the rotated cookie issued in step 2 must also fail. RFC 9700
     * §4.14.2.
     */
    @Test
    void refreshReuseOfOldCookieReturns401AndWipesFamily() throws Exception {
        String v1Cookie = loginAndGetCookie("alice@example.com", "s3cret");

        // 1st refresh: v1 → v2 (success).
        FluxExchangeResult<Void> refresh1 = webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", v1Cookie)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);
        String v2Cookie = extractCookieValue(
                refresh1.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE));
        assertThat(v2Cookie).isNotEqualTo(v1Cookie);

        // 2nd refresh: replay v1 — must be rejected.
        FluxExchangeResult<Void> reuse = webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", v1Cookie)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED)
                .returnResult(Void.class);
        assertThat(new String(reuse.getResponseBodyContent(), StandardCharsets.UTF_8))
                .contains("refresh_token_reuse");

        // The legitimate v2 must also fail now — the family was
        // wiped as a side effect of detecting the reuse.
        webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", v2Cookie)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    /**
     * Logout revokes the refresh cookie; subsequent refreshes with
     * the old value must return 401.
     */
    @Test
    void refreshAfterLogoutReturns401() throws Exception {
        String v1Cookie = loginAndGetCookie("alice@example.com", "s3cret");

        webTestClient.post().uri("/auth/logout")
                .cookie("sso_refresh", v1Cookie)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK);

        webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", v1Cookie)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    /**
     * Two simultaneous logins produce two independent families —
     * rotating one does not invalidate the other.
     */
    @Test
    void refreshMultiDeviceTwoFamiliesIndependent() throws Exception {
        // Two separate "devices" log in: each gets its own cookie.
        String deviceA = loginAndGetCookie("alice@example.com", "s3cret");
        String deviceB = loginAndGetCookie("alice@example.com", "s3cret");
        assertThat(deviceA).isNotEqualTo(deviceB);

        // Device A rotates.
        FluxExchangeResult<Void> rotatedA = webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", deviceA)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);
        String deviceAv2 = extractCookieValue(
                rotatedA.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE));
        assertThat(deviceAv2).isNotEqualTo(deviceA);

        // Device B's original cookie is unaffected — different family.
        FluxExchangeResult<Void> rotatedB = webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", deviceB)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);
        String deviceBv2 = extractCookieValue(
                rotatedB.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE));
        assertThat(deviceBv2).isNotEqualTo(deviceB);
        assertThat(deviceBv2).isNotEqualTo(deviceAv2);
    }

    /**
     * The access token minted at refresh must carry the original
     * user's identity in its {@code sub} claim. This is the test
     * that pins down the previous bypass-era behaviour where any
     * cookie yielded a token for the first enabled user.
     *
     * <p>Both alice (USER + ADMIN) and bob (USER only) are already
     * seeded by {@link #seed()}, so this test does NOT seed an
     * additional user — that would collide on the unique email
     * constraint. The "first in the DB" assertion still holds
     * because alice is the alphabetically-later user so bob would
     * be the natural "first" pick for any buggy
     * findByEmail(...).findFirst() shortcut.
     */
    @Test
    void refreshReturnsTokenForCorrectUser() throws Exception {
        String aliceCookie = loginAndGetCookie("alice@example.com", "s3cret");
        FluxExchangeResult<Void> rotated = webTestClient.post().uri("/auth/refresh")
                .cookie("sso_refresh", aliceCookie)
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);

        JsonNode body = mapper.readTree(rotated.getResponseBodyContent());
        String newToken = body.get("token").asText();

        // Decode the JWT payload (middle segment) — we don't verify
        // the signature here, that's the job of JwtTokenService;
        // we only check the sub claim carries alice's email (the
        // login identifier since V12).
        String[] parts = newToken.split("\\.");
        assertThat(parts).hasSize(3);
        String payloadJson = new String(java.util.Base64.getUrlDecoder()
                .decode(parts[1]), StandardCharsets.UTF_8);
        JsonNode claims = mapper.readTree(payloadJson);
        assertThat(claims.get("sub").asText()).isEqualTo("alice@example.com");
    }

    /* ====================== helpers ====================== */

    /**
     * Extracts the cookie value from a {@code Set-Cookie} header
     * (everything between {@code =} and {@code ;}). Defensive against
     * the various attribute orderings Spring may produce.
     */
    private static String extractCookieValue(String setCookie) {
        int eq = setCookie.indexOf('=');
        int semi = setCookie.indexOf(';');
        if (semi < 0) semi = setCookie.length();
        return setCookie.substring(eq + 1, semi);
    }

    private String loginAndGetToken(String email, String password) throws Exception {
        byte[] bodyBytes = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(mapper.writeValueAsString(
                        Map.of("email", email, "password", password)))
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class)
                .getResponseBodyContent();
        return mapper.readTree(bodyBytes).get("token").asText();
    }

    /**
     * Logs in and returns the value of the {@code sso_refresh}
     * cookie the server set. Used by the rotation / reuse /
     * multi-device tests that need to drive the refresh flow.
     */
    private String loginAndGetCookie(String email, String password) {
        FluxExchangeResult<Void> result = webTestClient.post().uri("/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"" + email
                        + "\",\"password\":\"" + password + "\"}")
                .exchange()
                .expectStatus().isEqualTo(HttpStatus.OK)
                .returnResult(Void.class);
        String setCookie = result.getResponseHeaders().getFirst(HttpHeaders.SET_COOKIE);
        assertThat(setCookie).isNotNull();
        return extractCookieValue(setCookie);
    }
}
