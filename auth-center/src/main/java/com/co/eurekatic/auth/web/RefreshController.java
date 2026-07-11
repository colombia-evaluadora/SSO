package com.co.eurekatic.auth.web;

import com.co.eurekatic.auth.security.EffectiveRolesResolver;
import com.co.eurekatic.auth.security.JsonLoginFilter;
import com.co.eurekatic.common.dto.AuthDtos.TokenResponse;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.common.security.RefreshTokenStore;
import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.Set;

/**
 * Cookie-based token refresh + logout. The
 * {@link JsonLoginFilter#REFRESH_COOKIE_NAME} cookie delivered at
 * login is the credential these endpoints read.
 *
 * <p>Both endpoints are deliberately {@code permitAll()} in
 * {@code SecurityConfig} — the cookie itself is the auth. CSRF stays
 * disabled because the cookie is {@code SameSite=Strict} (a cross-site
 * request cannot carry it).
 *
 * <h2>Refresh</h2>
 * <p>Reads the {@code sso_refresh} cookie, calls
 * {@link RefreshTokenStore#rotate(String)}, and on success mints a
 * new access token + sets the rotated cookie.
 *
 * <h2>Logout</h2>
 * <p>Calls {@link RefreshTokenStore#revokeToken(String)} (which
 * wipes the entire family) and then clears the cookie client-side.
 */
@RestController
@RequestMapping("/auth")
public class RefreshController {

    private static final Logger log = LoggerFactory.getLogger(RefreshController.class);

    private final RefreshTokenStore refreshTokenStore;
    private final UserRepository userRepository;
    private final JwtTokenService jwt;
    private final JwtProperties props;
    private final EffectiveRolesResolver effectiveRoles;

    public RefreshController(RefreshTokenStore refreshTokenStore,
                              UserRepository userRepository,
                              JwtTokenService jwt,
                              JwtProperties props,
                              EffectiveRolesResolver effectiveRoles) {
        this.refreshTokenStore = refreshTokenStore;
        this.userRepository = userRepository;
        this.jwt = jwt;
        this.props = props;
        this.effectiveRoles = effectiveRoles;
    }

    /**
     * Reads the {@code sso_refresh} cookie and exchanges it for a
     * fresh access token. The cookie's value is validated against
     * {@link RefreshTokenStore#rotate(String)} — if the token is
     * unknown, expired, or already consumed, the request is
     * rejected. Reuse of an already-rotated cookie wipes the entire
     * family (RFC 9700 §4.14.2).
     */
    @PostMapping("/refresh")
    public ResponseEntity<?> refresh(HttpServletRequest request,
                                       HttpServletResponse response) {
        String raw = readRefreshCookie(request);
        if (raw == null || raw.isBlank()) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "no_refresh_cookie"));
        }

        RefreshTokenStore.RefreshOutcome outcome;
        try {
            outcome = refreshTokenStore.rotate(raw);
        } catch (RuntimeException e) {
            // Defensive catch — implementations are expected to map
            // their failures to the sealed RefreshOutcome, but if
            // something escapes we still fail closed.
            log.error("Unexpected exception from refreshTokenStore.rotate", e);
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "store_unavailable"));
        }

        if (outcome instanceof RefreshTokenStore.RefreshOutcome.Unavailable) {
            log.error("Refresh-token store unavailable; failing closed (401)");
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "store_unavailable"));
        }
        if (outcome instanceof RefreshTokenStore.RefreshOutcome.NotFound) {
            log.info("Refresh cookie not found / expired / never minted");
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "invalid_refresh_cookie"));
        }
        if (outcome instanceof RefreshTokenStore.RefreshOutcome.ReuseDetected reuse) {
            log.warn("Refresh-token reuse detected; family wiped — user={} family={} ip={}",
                    reuse.email(), reuse.familyId(), clientIp(request));
            // Clear the cookie so the browser stops presenting the
            // stolen value.
            response.addHeader(HttpHeaders.SET_COOKIE, buildClearCookie(request));
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "refresh_token_reuse"));
        }

        RefreshTokenStore.RefreshOutcome.Rotated rotated =
                (RefreshTokenStore.RefreshOutcome.Rotated) outcome;
        RefreshTokenStore.RefreshTokenHandle next = rotated.next();

        // We need the user's roles to mint the access token. The
        // store only carries email + userId; the role list is
        // loaded from the DB. This is one indexed lookup per
        // refresh — acceptable cost for keeping the store contract
        // minimal. The email is recovered by peeking the freshly-
        // minted record (rotate's MULTI block already wrote the new
        // hash + family-membership before returning).
        RefreshTokenStore.RefreshTokenLookup lookup = refreshTokenStore.peek(next.rawToken());
        if (lookup == null) {
            // rotate() guarantees the new token is in the store
            // before returning; this branch should be unreachable.
            log.error("Refresh rotated but peek returned null; revoking rotated token");
            try {
                refreshTokenStore.revokeToken(next.rawToken());
            } catch (RuntimeException ignored) {
                // best-effort cleanup
            }
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "user_not_found"));
        }

        User user = userRepository.findByEmail(lookup.email()).orElse(null);
        if (user == null) {
            log.error("Refresh rotated but user {} no longer exists; revoking rotated token",
                    lookup.email());
            try {
                refreshTokenStore.revokeToken(next.rawToken());
            } catch (RuntimeException ignored) {
                // best-effort cleanup
            }
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "user_not_found"));
        }

        Set<String> roles = effectiveRoles.forEmail(user.getEmail());
        String accessToken = jwt.issueAccessToken(user.getEmail(), roles);

        response.addHeader(HttpHeaders.SET_COOKIE,
                JsonLoginFilter.buildRefreshCookie(next.rawToken(), next.ttlSeconds(), request));

        return ResponseEntity.ok(new TokenResponse(
                accessToken, next.rawToken(), props.accessTokenTtlSeconds()));
    }

    /**
     * Revokes the refresh-token family and clears the cookie.
     * Idempotent — calling it twice (or without a cookie) is a no-op.
     */
    @PostMapping("/logout")
    public ResponseEntity<Map<String, String>> logout(HttpServletRequest request,
                                                      HttpServletResponse response) {
        String raw = readRefreshCookie(request);
        if (raw != null && !raw.isBlank()) {
            try {
                refreshTokenStore.revokeToken(raw);
                log.info("Refresh-token family revoked on logout");
            } catch (RuntimeException e) {
                // Best-effort. We still clear the cookie so the
                // browser stops presenting the value; the next
                // /auth/refresh attempt will return NotFound and the
                // SPA will fall back to a clean re-login.
                log.warn("Failed to revoke refresh-token on logout", e);
            }
        }

        response.addHeader(HttpHeaders.SET_COOKIE, buildClearCookie(request));
        return ResponseEntity.ok(Map.of("status", "logged_out"));
    }

    /* ====================== helpers ====================== */

    private static String readRefreshCookie(HttpServletRequest request) {
        Cookie[] cookies = request.getCookies();
        if (cookies == null) return null;
        for (Cookie c : cookies) {
            if (JsonLoginFilter.REFRESH_COOKIE_NAME.equals(c.getName())) {
                return c.getValue();
            }
        }
        return null;
    }

    /**
     * Max-Age=0 + matching Path / SameSite / Secure attributes so
     * the browser actually deletes the cookie. Mismatched
     * attributes are the most common reason logout cookies don't
     * take effect.
     */
    private static String buildClearCookie(HttpServletRequest request) {
        boolean secure = request.isSecure();
        StringBuilder sb = new StringBuilder(64);
        sb.append(JsonLoginFilter.REFRESH_COOKIE_NAME).append('=')
          .append("; Path=").append(JsonLoginFilter.REFRESH_COOKIE_PATH)
          .append("; Max-Age=0")
          .append("; HttpOnly")
          .append("; SameSite=Strict");
        if (secure) sb.append("; Secure");
        return sb.toString();
    }

    private static String clientIp(HttpServletRequest request) {
        String forwarded = request.getHeader("X-Forwarded-For");
        if (forwarded != null && !forwarded.isBlank()) {
            return forwarded.split(",")[0].trim();
        }
        return request.getRemoteAddr();
    }
}
