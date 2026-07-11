package com.co.eurekatic.common.security;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jws;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Stateless JWT issuer + parser. Used by:
 * <ul>
 *   <li>{@code auth-center} to mint access tokens at login</li>
 *   <li>{@code api-gateway} to validate Bearer tokens on incoming requests</li>
 * </ul>
 *
 * <p>Modernized to the jjwt 0.12.x API ({@code parser().verifyWith(...)},
 * {@code parseSignedClaims()}, {@code signWith(key, Jwts.SIG.HS256)}) —
 * the 0.7.0 chain in the legacy code is gone.
 *
 * <p>HS256 is used so the same key both signs and verifies. The key is
 * derived from {@link JwtProperties#secret()} bytes (UTF-8). The
 * {@link Keys#hmacShaKeyFor(byte[])} factory throws
 * {@code WeakKeyException} if the secret is shorter than 32 bytes,
 * which is exactly the HS256 minimum.
 */
public class JwtTokenService {

    private static final String CLAIM_ROLES = "roles";
    private static final String CLAIM_TOKEN_TYPE = "typ";

    private final JwtProperties props;
    private final SecretKey key;

    public JwtTokenService(JwtProperties props) {
        this.props = props;
        this.key = Keys.hmacShaKeyFor(props.secret().getBytes(StandardCharsets.UTF_8));
    }

    /* ====================== issue ====================== */

    /**
     * Issue a short-lived access token. The {@code sub} claim carries the
     * user's email (the login identifier since the V12 migration); the
     * {@code roles} claim carries the role names.
     */
    public String issueAccessToken(String email, Set<String> roles) {
        return build(email, roles, "access", props.accessTokenTtlSeconds());
    }

    /**
     * Issue a longer-lived API token. Carries the same claims as the
     * access token but a different {@code typ} so gateways and clients
     * can distinguish them and apply different rate limits / cache TTLs.
     */
    public String issueApiToken(String email, Set<String> roles) {
        return build(email, roles, "api", props.apiTokenTtlSeconds());
    }

    private String build(String email, Set<String> roles, String tokenType, long ttlSeconds) {
        Instant now = Instant.now();
        return Jwts.builder()
                .subject(email)
                .issuer(props.issuer())
                .claim(CLAIM_ROLES, List.copyOf(roles == null ? Set.of() : roles))
                .claim(CLAIM_TOKEN_TYPE, tokenType)
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plusSeconds(ttlSeconds)))
                .signWith(key, Jwts.SIG.HS256)
                .compact();
    }

    /* ====================== parse ====================== */

    /**
     * Parse and verify a compact JWS string. Returns an {@link AuthPrincipal}
     * populated from the standard claims plus {@code roles} and {@code typ}.
     *
     * @throws JwtException if the token is malformed, has an invalid
     *         signature, has expired, or fails any of jjwt's default
     *         validations (issuer match, exp, etc. are NOT enforced
     *         here — see {@link #parseAndValidateIssuer}).
     */
    public AuthPrincipal parse(String token) {
        return parseInternal(token, false);
    }

    /**
     * Same as {@link #parse(String)} but additionally verifies that the
     * token's {@code iss} claim matches the configured issuer. Use this
     * variant on the api-gateway filter to make sure tokens minted by a
     * foreign system can't be replayed against us.
     */
    public AuthPrincipal parseAndValidateIssuer(String token) {
        return parseInternal(token, true);
    }

    @SuppressWarnings("unchecked")
    private AuthPrincipal parseInternal(String token, boolean requireIssuerMatch) {
        if (token == null || token.isBlank()) {
            throw new JwtException("Empty token");
        }
        var parserBuilder = Jwts.parser().verifyWith(key);
        if (requireIssuerMatch) {
            parserBuilder.requireIssuer(props.issuer());
        }
        Jws<Claims> jws = parserBuilder.build().parseSignedClaims(token);
        Claims claims = jws.getPayload();

        Set<String> roles = new LinkedHashSet<>();
        Object rawRoles = claims.get(CLAIM_ROLES);
        if (rawRoles instanceof List<?> list) {
            for (Object r : list) {
                if (r != null) {
                    roles.add(r.toString());
                }
            }
        } else if (rawRoles instanceof String s) {
            // tolerate a single-role token where the claim is a bare string
            roles.add(s);
        }

        String tokenType = claims.get(CLAIM_TOKEN_TYPE, String.class);
        if (tokenType == null) {
            tokenType = "access";
        }

        return new AuthPrincipal(claims.getSubject(), roles, tokenType);
    }
}
