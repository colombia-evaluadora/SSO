package com.co.eurekatic.common.audit;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Espejo de las pruebas de {@code QueryService.injectRequestParams} en
 * query-service — mismo comportamiento, extraído a {@code common}.
 */
class AuditContextExtractorTest {

    @AfterEach
    void clearRequestContext() {
        RequestContextHolder.resetRequestAttributes();
    }

    @Test
    void returnsEmptyWhenNoRequestIsBoundToTheThread() {
        assertThat(AuditContextExtractor.fromCurrentRequest(Map.of())).isEmpty();
    }

    @Test
    void capturesClientIpFromXClientIpHeaderFirst() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/auth-center/register/usuario");
        req.addHeader("X-Client-Ip", "203.0.113.7");
        req.addHeader("X-Forwarded-For", "10.0.0.1, 10.0.0.2");
        req.setRemoteAddr("172.18.0.5");
        bind(req);

        Optional<AuditContext> ctx = AuditContextExtractor.fromCurrentRequest(Map.of());

        assertThat(ctx).isPresent();
        assertThat(ctx.get().clientIp()).isEqualTo("203.0.113.7");
        assertThat(ctx.get().httpMethod()).isEqualTo("POST");
    }

    @Test
    void fallsBackToXForwardedForThenRemoteAddr() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        req.addHeader("X-Forwarded-For", "10.0.0.1, 10.0.0.2");
        req.setRemoteAddr("172.18.0.5");
        bind(req);

        assertThat(AuditContextExtractor.fromCurrentRequest(Map.of()).get().clientIp())
                .isEqualTo("10.0.0.1");

        RequestContextHolder.resetRequestAttributes();
        MockHttpServletRequest req2 = new MockHttpServletRequest("POST", "/x");
        req2.setRemoteAddr("172.18.0.5");
        bind(req2);

        assertThat(AuditContextExtractor.fromCurrentRequest(Map.of()).get().clientIp())
                .isEqualTo("172.18.0.5");
    }

    @Test
    void onlyCapturesWhitelistedHeaders() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        req.addHeader("User-Agent", "curl/8.0");
        req.addHeader("Authorization", "Bearer secret-token");
        req.addHeader("Cookie", "session=abc123");
        bind(req);

        Map<String, String> headers = AuditContextExtractor.fromCurrentRequest(Map.of()).get().headers();

        assertThat(headers).containsEntry("user-agent", "curl/8.0");
        assertThat(headers).doesNotContainKey("authorization");
        assertThat(headers).doesNotContainKey("cookie");
    }

    @Test
    void redactsSensitiveBodyKeysBeforeSerializing() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        Map<String, Object> body = Map.of(
                "BODY.EMAIL", "alice@example.com",
                "BODY.PASSWORD", "hunter2",
                "CONTEXT.TOKEN", "eyJ...");

        String json = AuditContextExtractor.fromCurrentRequest(body).get().requestBodyJson();

        assertThat(json).contains("alice@example.com");
        assertThat(json).doesNotContain("hunter2").doesNotContain("eyJ...");
        assertThat(json).contains("[REDACTED]");
    }

    /**
     * El caso que se escapaba: {@code FuncionarioRegistrationService}
     * arma su snapshot con {@code convertValue(dto, Map.class)}, así
     * que un objeto anidado del DTO llega como un Map dentro del
     * valor. La key de primer nivel ("credenciales") no matchea el
     * patrón, y antes el password de dentro viajaba en claro hasta
     * {@code app.request_body} y de ahí a ClickHouse.
     */
    @Test
    void redactsSensitiveKeysNestedInsideObjects() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        Map<String, Object> body = Map.of(
                "correo", "alice@example.com",
                "credenciales", Map.of(
                        "usuario", "alice",
                        "password", "hunter2"));

        String json = AuditContextExtractor.fromCurrentRequest(body).get().requestBodyJson();

        assertThat(json).contains("alice@example.com").contains("alice");
        assertThat(json).doesNotContain("hunter2");
        assertThat(json).contains("[REDACTED]");
    }

    @Test
    void redactsSensitiveKeysInsideLists() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        Map<String, Object> body = Map.of(
                "usuarios", java.util.List.of(
                        Map.of("correo", "a@x.com", "contrasena", "secreta-1"),
                        Map.of("correo", "b@x.com", "contrasena", "secreta-2")));

        String json = AuditContextExtractor.fromCurrentRequest(body).get().requestBodyJson();

        assertThat(json).contains("a@x.com").contains("b@x.com");
        assertThat(json).doesNotContain("secreta-1").doesNotContain("secreta-2");
    }

    @Test
    void keepsRedactingFlatNamespacedKeys() {
        // No romper el caso que ya funcionaba: el catálogo aplana los
        // bodies como BODY.USUARIO.PASSWORD y se corta en el primer punto.
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        Map<String, Object> body = Map.of(
                "BODY.USUARIO.PASSWORD", "hunter2",
                "BODY.USUARIO.CORREO", "alice@example.com");

        String json = AuditContextExtractor.fromCurrentRequest(body).get().requestBodyJson();

        assertThat(json).doesNotContain("hunter2");
        assertThat(json).contains("alice@example.com");
    }

    @Test
    void nullValuesSurviveRedaction() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        Map<String, Object> body = new java.util.LinkedHashMap<>();
        body.put("correo", null);
        body.put("anidado", java.util.Collections.singletonMap("password", null));

        String json = AuditContextExtractor.fromCurrentRequest(body).get().requestBodyJson();

        assertThat(json).isNotNull();
    }

    @Test
    void emptyBodyYieldsNullRequestBodyJson() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        assertThat(AuditContextExtractor.fromCurrentRequest(Map.of()).get().requestBodyJson()).isNull();
        assertThat(AuditContextExtractor.fromCurrentRequest(null).get().requestBodyJson()).isNull();
    }

    @Test
    void generatesARequestIdWhenTheCallerDidNotSendOne() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        bind(req);

        assertThat(AuditContextExtractor.fromCurrentRequest(Map.of()).get().requestId()).isNotBlank();
    }

    @Test
    void reusesTheCallersXRequestIdHeaderWhenPresent() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/x");
        req.addHeader("X-Request-Id", "req-123");
        bind(req);

        assertThat(AuditContextExtractor.fromCurrentRequest(Map.of()).get().requestId()).isEqualTo("req-123");
    }

    private static void bind(MockHttpServletRequest req) {
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(req));
    }
}
