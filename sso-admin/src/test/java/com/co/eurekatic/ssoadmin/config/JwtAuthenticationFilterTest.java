package com.co.eurekatic.ssoadmin.config;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.LinkedHashSet;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Verifies the {@link JwtAuthenticationFilter} wires the JWT
 * principal into Spring Security's context — the integration
 * test then asserts the chain's {@code hasRole("ADMIN")} rule
 * kicks in on top.
 */
@ExtendWith(MockitoExtension.class)
class JwtAuthenticationFilterTest {

    @Mock JwtTokenService jwt;
    @Mock FilterChain chain;

    private JwtAuthenticationFilter filter;
    private JwtProperties props;

    @BeforeEach
    void setUp() {
        props = new JwtProperties(
                "test-secret-which-is-at-least-32-bytes-long-1234567890",
                "sso-postgres",
                3600L,
                86400L,
                "Authorization",
                "Bearer ");
        filter = new JwtAuthenticationFilter(jwt, props);
        SecurityContextHolder.clearContext();
    }

    @Test
    void rejectsRequestWithoutAuthHeader() throws Exception {
        MockHttpServletRequest req = new MockHttpServletRequest("GET", "/getUsers");
        MockHttpServletResponse resp = new MockHttpServletResponse();

        filter.doFilter(req, resp, chain);

        verify(chain).doFilter(req, resp);
        assertThat(SecurityContextHolder.getContext().getAuthentication()).isNull();
    }

    @Test
    void rejectsRequestWithWrongHeaderPrefix() throws Exception {
        MockHttpServletRequest req = new MockHttpServletRequest("GET", "/getUsers");
        req.addHeader("Authorization", "Basic dXNlcjpwYXNz");
        MockHttpServletResponse resp = new MockHttpServletResponse();

        filter.doFilter(req, resp, chain);

        verify(chain).doFilter(req, resp);
        assertThat(SecurityContextHolder.getContext().getAuthentication()).isNull();
    }

    @Test
    void populatesSecurityContextOnValidBearerToken() throws Exception {
        MockHttpServletRequest req = new MockHttpServletRequest("GET", "/getUsers");
        req.addHeader("Authorization", "Bearer good-token");
        MockHttpServletResponse resp = new MockHttpServletResponse();

        AuthPrincipal principal = new AuthPrincipal("alice", new LinkedHashSet<>(Set.of("ADMIN")), "access");
        when(jwt.parse("good-token")).thenReturn(principal);

        filter.doFilter(req, resp, chain);

        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        assertThat(auth).isNotNull();
        // The principal is the AuthPrincipal record itself.
        assertThat(auth.getPrincipal()).isInstanceOf(AuthPrincipal.class);
        assertThat(((AuthPrincipal) auth.getPrincipal()).email()).isEqualTo("alice");
        assertThat(auth.getAuthorities())
                .extracting(Object::toString)
                .contains("ROLE_ADMIN");
        verify(chain).doFilter(req, resp);
    }

    @Test
    void clearsContextOnJwtParseFailure() throws Exception {
        MockHttpServletRequest req = new MockHttpServletRequest("GET", "/getUsers");
        req.addHeader("Authorization", "Bearer bad-token");
        MockHttpServletResponse resp = new MockHttpServletResponse();

        when(jwt.parse("bad-token")).thenThrow(new JwtException("bad signature"));

        // Should NOT throw — the filter is non-blocking; the
        // chain's hasRole("ADMIN") rule will reject downstream.
        filter.doFilter(req, resp, chain);

        assertThat(SecurityContextHolder.getContext().getAuthentication()).isNull();
        verify(chain).doFilter(req, resp);
    }

    @Test
    void rejectsEmptyBearerToken() throws Exception {
        MockHttpServletRequest req = new MockHttpServletRequest("GET", "/getUsers");
        req.addHeader("Authorization", "Bearer    ");
        MockHttpServletResponse resp = new MockHttpServletResponse();

        filter.doFilter(req, resp, chain);

        assertThat(SecurityContextHolder.getContext().getAuthentication()).isNull();
        verify(jwt, org.mockito.Mockito.never()).parse(anyString());
    }
}
