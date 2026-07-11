package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.dto.AuthDtos.LoginRequest;
import com.co.eurekatic.common.dto.AuthDtos.TokenResponse;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.common.security.RefreshTokenStore;
import com.co.eurekatic.common.security.RefreshUnavailableException;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.web.authentication.AbstractAuthenticationProcessingFilter;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;

import java.io.IOException;
import java.time.Instant;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Servlet filter that handles {@code POST /login} by reading a JSON body,
 * authenticating the user via the {@link AuthenticationManager}, and on
 * success returning a compact JWS plus a refresh token.
 *
 * <p>Modernized from the legacy
 * {@code com.co.lowcode.security.common.JwtUsernamePasswordAuthenticationFilter}
 * (jjwt 0.7, returns LoginResponse with routes list) — the modernized
 * version uses jjwt 0.12 and {@link TokenResponse}, deferring route
 * lookup to {@code /getRoutes} so the token stays slim.
 *
 * <p>The refresh token is now minted via {@link RefreshTokenStore}
 * (Redis-backed, see {@code RedisRefreshTokenStore}). Storing it
 * server-side lets us rotate on every refresh and detect reuse
 * (RFC 9700 §4.14).
 */
public class JsonLoginFilter extends AbstractAuthenticationProcessingFilter {

    private final JwtTokenService jwt;
    private final ObjectMapper mapper;
    private final JwtProperties props;
    private final RefreshTokenStore refreshTokenStore;
    private final EffectiveRolesResolver effectiveRoles;

    public JsonLoginFilter(AuthenticationManager authenticationManager,
                           JwtTokenService jwt,
                           ObjectMapper mapper,
                           JwtProperties props,
                           RefreshTokenStore refreshTokenStore,
                           EffectiveRolesResolver effectiveRoles) {
        // Spring Security 7 migration: AntPathRequestMatcher (from
        // spring-security-web 6.x) was removed. The replacement is
        // PathPatternRequestMatcher, built from Spring's PathPatternParser
        // (the modern matcher used elsewhere in Spring 6/7). The factory
        // pathPattern(HttpMethod, String) returns a RequestMatcher for the
        // given path + HTTP method; AbstractAuthenticationProcessingFilter
        // still takes a RequestMatcher, so this is a drop-in.
        super(PathPatternRequestMatcher.pathPattern(HttpMethod.POST, "/login"));
        super.setAuthenticationManager(authenticationManager);
        this.jwt = jwt;
        this.mapper = mapper;
        this.props = props;
        this.refreshTokenStore = refreshTokenStore;
        this.effectiveRoles = effectiveRoles;
        // We are stateless; do not create or persist HttpSession-bound
        // security contexts across requests.
        setSecurityContextRepository(new org.springframework.security.web.context.NullSecurityContextRepository());
    }

    @Override
    public Authentication attemptAuthentication(HttpServletRequest request,
                                                HttpServletResponse response)
            throws AuthenticationException {
        try {
            LoginRequest body = mapper.readValue(request.getInputStream(), LoginRequest.class);
            UsernamePasswordAuthenticationToken token =
                    UsernamePasswordAuthenticationToken.unauthenticated(body.email(), body.password());
            token.setDetails(authenticationDetailsSource.buildDetails(request));
            return getAuthenticationManager().authenticate(token);
        } catch (IOException e) {
            throw new BadLoginRequestException("Malformed login body: " + e.getMessage());
        }
    }

    @Override
    protected void successfulAuthentication(HttpServletRequest request,
                                            HttpServletResponse response,
                                            FilterChain chain,
                                            Authentication authResult)
            throws IOException, ServletException {

        Object principal = authResult.getPrincipal();
        // Email is the login identifier since the V12 migration
        // (the prior username column is gone). We read it off the
        // entity's email field (which UserDetails.getUsername() also
        // returns — both are kept consistent).
        String email = (principal instanceof User u) ? u.getEmail() : authResult.getName();
        String userId = (principal instanceof User u && u.getId() != null)
                ? String.valueOf(u.getId())
                : email;
        Set<String> roles = effectiveRoles.forEmail(email);

        String accessToken = jwt.issueAccessToken(email, roles);

        // Mint a new refresh token via the store. Each login starts a
        // fresh family so multi-device sessions are independent. If the
        // store is unreachable we fail the login (503) — never fall
        // back to an unstored token (that's the bypass we're fixing).
        String refreshToken;
        long ttlSeconds;
        try {
            String familyId = UUID.randomUUID().toString().replace("-", "");
            RefreshTokenStore.RefreshTokenHandle handle =
                    refreshTokenStore.mint(email, userId, familyId);
            refreshToken = handle.rawToken();
            ttlSeconds = handle.ttlSeconds();
        } catch (RefreshUnavailableException e) {
            response.setStatus(HttpServletResponse.SC_SERVICE_UNAVAILABLE);
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            response.setCharacterEncoding("UTF-8");
            mapper.writeValue(response.getOutputStream(), Map.of(
                    "timestamp", Instant.now().toString(),
                    "status", 503,
                    "error", "store_unavailable",
                    "message", "Authentication service temporarily unavailable"
            ));
            return;
        }

        // The refresh token is also delivered as an HttpOnly cookie so
        // the admin SPA (and any future browser-based client) can call
        // POST /auth/refresh without holding the refresh token in JS-
        // accessible storage. SameSite=Strict blocks cross-site requests;
        // HttpOnly blocks XSS exfiltration; Secure requires HTTPS in
        // production. Path=/ keeps the cookie scoped to both the
        // legacy /auth/refresh path AND the gateway-mounted
        // /api/auth/refresh path.
        response.addHeader(HttpHeaders.SET_COOKIE,
                buildRefreshCookie(refreshToken, ttlSeconds, request));

        response.setStatus(HttpServletResponse.SC_OK);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding("UTF-8");
        mapper.writeValue(response.getOutputStream(), new TokenResponse(
                accessToken, refreshToken, props.accessTokenTtlSeconds()));
    }

    /**
     * Backward-compatible overload that pins the Max-Age to the
     * default 30 days. Prefer {@link #buildRefreshCookie(String, long,
     * HttpServletRequest)} so the cookie's Max-Age tracks the
     * configured refresh-token TTL from {@code sso.refresh-token.ttl-seconds}.
     * Kept for callers that haven't yet been rewired to read the
     * configured TTL (e.g. {@code RefreshController} before the
     * store-aware rewrite lands).
     */
    public static String buildRefreshCookie(String refreshToken, HttpServletRequest request) {
        return buildRefreshCookie(refreshToken, REFRESH_COOKIE_MAX_AGE, request);
    }

    /**
     * Builds the {@code Set-Cookie} header value for the refresh token.
     * Kept static so the cookie shape is testable in isolation.
     * {@code Secure} is omitted when the request comes in over plain
     * HTTP (dev), added when the connection is TLS (prod). SameSite is
     * always Strict because the SPA never needs cross-site auth.
     *
     * <p>{@code maxAgeSeconds} is sourced from the
     * {@link RefreshTokenStore} (which itself reads
     * {@code sso.refresh-token.ttl-seconds}) so the browser-side hint
     * matches the server-side source of truth.
     */
    public static String buildRefreshCookie(String refreshToken, long maxAgeSeconds,
                                            HttpServletRequest request) {
        boolean secure = request.isSecure();
        StringBuilder sb = new StringBuilder(128);
        sb.append(REFRESH_COOKIE_NAME).append('=').append(refreshToken)
          .append("; Path=").append(REFRESH_COOKIE_PATH)
          .append("; Max-Age=").append(maxAgeSeconds)
          .append("; HttpOnly")
          .append("; SameSite=Strict");
        if (secure) {
            sb.append("; Secure");
        }
        return sb.toString();
    }

    public static final String REFRESH_COOKIE_NAME = "sso_refresh";
    // Path is "/" (not "/auth") so the cookie is sent on both the
    // legacy /auth/refresh path AND the gateway-mounted
    // /api/auth/refresh path. The browser matches the cookie's path
    // against the URL it actually requests, and from the browser's
    // perspective the SPA's refresh call goes to /api/auth/refresh
    // (the gateway's /api/** surface). HttpOnly + SameSite=Strict +
    // the lack of a cross-site need keep the security posture
    // intact; the path scoping was defense-in-depth that broke when
    // the gateway added an /api prefix.
    public static final String REFRESH_COOKIE_PATH = "/";
    /** Default 30 days. Mirrored from {@code sso.refresh-token.ttl-seconds} via the store. */
    public static final int REFRESH_COOKIE_MAX_AGE = 30 * 24 * 60 * 60;

    @Override
    protected void unsuccessfulAuthentication(HttpServletRequest request,
                                              HttpServletResponse response,
                                              AuthenticationException failed)
            throws IOException, ServletException {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding("UTF-8");
        mapper.writeValue(response.getOutputStream(), Map.of(
                "timestamp", Instant.now().toString(),
                "status", 401,
                "error", "authentication_failed",
                "message", failed.getMessage() == null ? "Bad credentials" : failed.getMessage()
        ));
    }

    /**
     * Marker exception so the global entry point can return 400 instead
     * of 401 when the JSON body is malformed (vs. bad credentials).
     */
    public static class BadLoginRequestException extends AuthenticationException {
        public BadLoginRequestException(String msg) {
            super(msg);
        }
    }
}