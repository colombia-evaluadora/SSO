package com.co.eurekatic.ssoadmin.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.security.MessageDigest;

/**
 * V30 — shared-secret gate for the {@code /internal/**} surface
 * (currently {@code /internal/gateway/routes} and
 * {@code /internal/issuePathRegistryToken}).
 *
 * <p>The gateway and the query-service path-registry sit on
 * the same docker network as sso-admin, but "private network"
 * is a weak trust boundary once a misconfigured port mapping
 * or a sidecar joins the wrong compose project. A shared
 * secret adds defense in depth: even if the network leaks,
 * requests still need a value only the operator knows.
 *
 * <p>The secret is operator-configured via
 * {@code sso.internal.token} (default
 * {@code "change-me-internal-token"} so a misconfigured
 * deployment fails closed at boot — the operator MUST set it
 * for the filter to actually pass anything). The constant-time
 * compare via {@link MessageDigest#isEqual(byte[], byte[])}
 * defeats timing attacks.
 *
 * <p>Anonymous paths other than {@code /internal/**} are not
 * touched by this filter — they're handled by
 * {@code SecurityConfig}'s {@code permitAll()} matchers.
 */
// V30 — NOT a @Component. Spring Boot would auto-register
// any @Component Filter as a global servlet filter with
// order=LOWEST, which conflicts with the Spring Security
// chain (and "Filter class X does not have a registered
// order" surfaces when the chain builder can't place the
// filter). We register the bean explicitly in
// {@link com.co.eurekatic.ssoadmin.config.InternalTokenConfig}
// as a {@code FilterRegistrationBean<InternalTokenFilter>}
// with order=HIGHEST_PRECEDENCE so it runs BEFORE every
// other filter (including Spring Security's chain).
public class InternalTokenFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(InternalTokenFilter.class);

    static final String HEADER = "X-Internal-Token";
    static final String INTERNAL_PATH_PREFIX = "/internal/";

    private final byte[] expected;

    public InternalTokenFilter(@Value("${sso.internal.token:change-me-internal-token}") String token) {
        if ("change-me-internal-token".equals(token)) {
            log.warn("sso.internal.token is set to the default placeholder; "
                    + "the /internal/** surface will reject every request. "
                    + "Set the env var to a real value in .env / compose.");
        }
        this.expected = token.getBytes();
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        // Only guard the /internal/** surface. Everything
        // else flows through the regular security chain.
        return !request.getRequestURI().startsWith(INTERNAL_PATH_PREFIX);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String presented = request.getHeader(HEADER);
        if (presented == null || presented.isBlank()) {
            log.warn("Rejected {} {} — missing {} header",
                    request.getMethod(), request.getRequestURI(), HEADER);
            unauthorized(response);
            return;
        }
        byte[] presentedBytes = presented.getBytes();
        if (!MessageDigest.isEqual(presentedBytes, expected)) {
            log.warn("Rejected {} {} — invalid {} header",
                    request.getMethod(), request.getRequestURI(), HEADER);
            unauthorized(response);
            return;
        }
        chain.doFilter(request, response);
    }

    private static void unauthorized(HttpServletResponse response) throws IOException {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType("application/json");
        response.getWriter().write(
                "{\"error\":\"internal_token_invalid\",\"message\":\"X-Internal-Token header is missing or wrong\"}");
    }
}
