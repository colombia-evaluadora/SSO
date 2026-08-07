package com.co.eurekatic.common.security;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jws;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.time.Instant;
import java.util.Base64;
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
 *
 * <p><b>V29 — caller context.</b> The {@code uid} claim carries the
 * numeric {@code users.id_user} so downstream services can pass it to
 * procedures without a DB lookup. Issued as a JSON number (Long);
 * tokens minted before V29 have no claim and parse to {@code null}.
 * See {@link AuthPrincipal#userId()}.
 */
public class JwtTokenService {

    private static final String CLAIM_ROLES = "roles";
    private static final String CLAIM_TOKEN_TYPE = "typ";
    private static final String CLAIM_USER_ID = "uid";

    private final JwtProperties props;
    /**
     * Mode-aware signing key. {@link #signingKey()} picks the right
     * one: HMAC ({@link SecretKey}) when {@code secret} is set,
     * RSA ({@link PrivateKey}) when {@code privateKey} is set.
     * A verifier-only service has neither and {@link #signingKey()}
     * throws — which is the right behavior because
     * {@link #canIssue()} would have returned false anyway.
     */
    private final SecretKey hmacKey;
    private final PrivateKey rsaPrivateKey;

    public JwtTokenService(JwtProperties props) {
        this.props = props;
        this.hmacKey = (props.secret() != null && !props.secret().isBlank())
                ? Keys.hmacShaKeyFor(props.secret().getBytes(StandardCharsets.UTF_8))
                : null;
        this.rsaPrivateKey = (props.privateKey() != null && !props.privateKey().isBlank())
                ? readRsaPrivateKey(props.privateKey())
                : null;
    }

    /** The key used to sign new tokens — null iff this service is verifier-only. */
    private Key signingKey() {
        if (hmacKey != null) return hmacKey;
        if (rsaPrivateKey != null) return rsaPrivateKey;
        return null;
    }

    /**
     * Parses an X.509 SubjectPublicKeyInfo PEM document into a
     * {@link java.security.PublicKey}. Symmetric helper to
     * {@link #readRsaPrivateKey(String)}.
     */
    private static java.security.PublicKey readRsaPublicKey(String pem) {
        String body = pem
                .replace("-----BEGIN PUBLIC KEY-----", "")
                .replace("-----END PUBLIC KEY-----", "")
                .replaceAll("\\s+", "");
        byte[] der = Base64.getDecoder().decode(body);
        try {
            java.security.spec.X509EncodedKeySpec spec =
                    new java.security.spec.X509EncodedKeySpec(der);
            return KeyFactory.getInstance("RSA").generatePublic(spec);
        } catch (Exception e) {
            // catches GeneralSecurityException + NoSuchAlgorithm +
            // InvalidKeySpec + IllegalArgument (bad base64 etc.)
            throw new IllegalStateException(
                    "sso.jwt.public-key is not a parseable RSA public key. "
                            + "Generate one with scripts/gen-jwt-keys.sh. Root cause: "
                            + e.getMessage(), e);
        }
    }

    /**
     * Parses a PKCS#8 PEM document into an {@link PrivateKey}. The
     * strip-and-decode dance matches what {@code scripts/gen-jwt-keys.sh}
     * emits; we tolerate either PKCS#1 or PKCS#8 with or without the
     * PEM armor.
     */
    private static PrivateKey readRsaPrivateKey(String pem) {
        String body = pem
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replace("-----BEGIN RSA PRIVATE KEY-----", "")
                .replace("-----END RSA PRIVATE KEY-----", "")
                .replaceAll("\\s+", "");
        byte[] der = Base64.getDecoder().decode(body);
        try {
            // PKCS#8 preferred.
            java.security.spec.PKCS8EncodedKeySpec spec =
                    new java.security.spec.PKCS8EncodedKeySpec(der);
            return KeyFactory.getInstance("RSA").generatePrivate(spec);
        } catch (java.security.spec.InvalidKeySpecException
                 | java.security.NoSuchAlgorithmException ignored) {
            // Fall back to PKCS#1 (older OpenSSL default).
            java.security.spec.X509EncodedKeySpec x509 =
                    new java.security.spec.X509EncodedKeySpec(der);
            return KeyFactory.getInstance("RSA").generatePrivate(x509);
        } catch (Exception e) {
            throw new IllegalStateException(
                    "sso.jwt.private-key is not a parseable RSA private key. "
                            + "Generate one with scripts/gen-jwt-keys.sh. Root cause: "
                            + e.getMessage(), e);
        }
    }

    /* ====================== issue ====================== */

    /**
     * Issue a short-lived access token. The {@code sub} claim carries the
     * user's email (the login identifier since the V12 migration); the
     * {@code roles} claim carries the role names; the {@code uid} claim
     * carries the numeric {@code users.id_user} (since V29) so the
     * downstream doesn't need a DB hit to know who the caller is.
     */
    public String issueAccessToken(String email, Long userId, Set<String> roles) {
        return build(email, userId, roles, "access", props.accessTokenTtlSeconds());
    }

    /**
     * Issue a longer-lived API token. Carries the same claims as the
     * access token but a different {@code typ} so gateways and clients
     * can distinguish them and apply different rate limits / cache TTLs.
     */
    public String issueApiToken(String email, Long userId, Set<String> roles) {
        return build(email, userId, roles, "api", props.apiTokenTtlSeconds());
    }

    /**
     * Back-compat overload for callers that haven't been rewired to
     * include {@code userId} yet. Issues a token WITHOUT the {@code uid}
     * claim; downstream services see {@code principal.userId() == null}.
     * Prefer the (email, userId, roles) form.
     */
    public String issueAccessToken(String email, Set<String> roles) {
        return issueAccessToken(email, null, roles);
    }

    /** Back-compat overload — see {@link #issueAccessToken(String, Set)}. */
    public String issueApiToken(String email, Set<String> roles) {
        return issueApiToken(email, null, roles);
    }

    private String build(String email, Long userId, Set<String> roles,
                         String tokenType, long ttlSeconds) {
        Instant now = Instant.now();
        var builder = Jwts.builder()
                .subject(email)
                .issuer(props.issuer())
                .claim(CLAIM_ROLES, List.copyOf(roles == null ? Set.of() : roles))
                .claim(CLAIM_TOKEN_TYPE, tokenType)
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plusSeconds(ttlSeconds)));

        // Only emit uid when we actually have it. Writing the claim
        // as null would (a) be ugly in the payload, and (b) trip up
        // downstream consumers that expect either a Long or the
        // claim's absence. Tokens without uid parse back to userId=null
        // and the caller (e.g. QueryService) skips injecting
        // :caller_user_id into the JDBC params.
        if (userId != null) {
            builder.claim(CLAIM_USER_ID, userId);
        }

        Key signingKey = signingKey();
        if (signingKey == null) {
            // Verifier-only service — issueAccessToken / issueApiToken
            // are still on the public API for symmetry, but the
            // signer refuses. Callers that need to issue tokens
            // (auth-center) configure sso.jwt.private-key OR sso.jwt.secret.
            throw new IllegalStateException(
                "JwtTokenService is verifier-only: no sso.jwt.private-key "
                    + "or sso.jwt.secret is configured. Run scripts/gen-jwt-keys.sh "
                    + "and set one of them in this service's .env / application.yml.");
        }
        return builder
                .signWith(signingKey)   // jjwt 0.12 picks the algorithm
                                          // from the Key type (HMAC for
                                          // SecretKey, RSA for RSAPrivateKey)
                .compact();
    }

    /* ====================== parse ====================== */

    /**
     * Parse and verify a compact JWS string. Returns an {@link AuthPrincipal}
     * populated from the standard claims plus {@code roles}, {@code typ},
     * and {@code uid}.
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
        // The verifier key matches the mode that was used to
        // sign. HMAC tokens verify with the same secret; RSA
        // tokens verify with the configured public key (a
        // verifier-only service uses publicKey alone — no
        // signingKey is required for verification).
        var parserBuilder = Jwts.parser();
        if (hmacKey != null) {
            parserBuilder.verifyWith(hmacKey);
        } else if (props.publicKey() != null && !props.publicKey().isBlank()) {
            parserBuilder.verifyWith(readRsaPublicKey(props.publicKey()));
        } else {
            throw new IllegalStateException(
                "JwtTokenService has neither sso.jwt.secret nor sso.jwt.public-key "
                    + "configured; cannot verify tokens. Set one in .env.");
        }
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

        Long userId = extractUserId(claims);

        return new AuthPrincipal(claims.getSubject(), userId, roles, tokenType);
    }

    /**
     * Reads the {@code uid} claim. jjwt deserializes JSON numbers as
     * {@link Integer} or {@link Long} depending on magnitude; we
     * accept both via {@link Number} and coerce to Long. Bare-string
     * uids (defensive — would only happen if a non-JJWT producer
     * emitted a token) are parsed via {@link Long#parseLong}.
     * Missing claim → null.
     */
    private static Long extractUserId(Claims claims) {
        Object raw = claims.get(CLAIM_USER_ID);
        if (raw == null) {
            return null;
        }
        if (raw instanceof Number n) {
            return n.longValue();
        }
        if (raw instanceof String s) {
            String trimmed = s.trim();
            if (trimmed.isEmpty()) {
                return null;
            }
            try {
                return Long.parseLong(trimmed);
            } catch (NumberFormatException e) {
                throw new JwtException("uid claim is not a valid Long: " + s);
            }
        }
        throw new JwtException("uid claim has unexpected type: " + raw.getClass().getName());
    }
}
