package com.co.eurekatic.common.security;

import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Unit tests for {@link JwtTokenService}. Pure POJO test — no Spring
 * context, no mocks. Verifies:
 * <ol>
 *   <li>Round-trip: issue → parse yields the same principal.</li>
 *   <li>Tampered tokens are rejected with {@link JwtException}.</li>
 *   <li>A token signed by a different key pair is rejected.</li>
 *   <li>A verifier without a private key can parse but not issue —
 *       the guarantee the RS256 migration exists to provide.</li>
 *   <li>Malformed PEM fails at construction, not at first use.</li>
 * </ol>
 */
class JwtTokenServiceTest {

    private static final KeyPair KEYS = generateKeyPair();
    private static final KeyPair OTHER_KEYS = generateKeyPair();

    /**
     * V29 — used by the legacy-token-without-uid tests to forge
     * an HS256 token (matching pre-V29 token shape). The
     * JwtTokenService accepts this token regardless of which
     * signing mode the local service uses (RSA or HMAC).
     */
    private static final String GOOD_SECRET =
            "this-is-a-test-secret-that-is-32-bytes-or-longer-1234567890";

    private static final JwtProperties DEFAULT_PROPS = propsFor(KEYS);

    private static KeyPair generateKeyPair() {
        try {
            KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
            gen.initialize(2048);
            return gen.generateKeyPair();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    /** Wraps a DER-encoded key in the PEM armor JwtTokenService expects. */
    private static String pem(String type, byte[] der) {
        return "-----BEGIN " + type + "-----\n"
                + Base64.getMimeEncoder(64, new byte[]{'\n'}).encodeToString(der)
                + "\n-----END " + type + "-----\n";
    }

    private static JwtProperties propsFor(KeyPair keys) {
        // The constructor signature passes the optional V29
        // 'secret' as the 8th arg so JwtTokenService's HS256
        // path has a key to use when its construction runs.
        // The constructor itself (canonical 8-arg) is what
        // JwtTokenService consumes; the back-compat 7-arg
        // overload (added during the main→test merge) lets
        // the existing 7-arg calls still compile. Both paths
        // converge on the same instance field set.
        return new JwtProperties(
                pem("PRIVATE KEY", keys.getPrivate().getEncoded()),
                pem("PUBLIC KEY", keys.getPublic().getEncoded()),
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer ",
                GOOD_SECRET);
    }

    /** Same key pair, but public half only — how every non-auth-center service is configured. */
    private static JwtProperties verifierOnlyProps(KeyPair keys) {
        return new JwtProperties(
                null,
                pem("PUBLIC KEY", keys.getPublic().getEncoded()),
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer ",
                GOOD_SECRET);
    }

    @Test
    void roundTripPreservesSubjectRolesAndIssuer() {
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);

        Set<String> roles = new LinkedHashSet<>();
        roles.add("USER");
        roles.add("ADMIN");

        String token = svc.issueAccessToken("alice", roles);
        AuthPrincipal principal = svc.parse(token);

        assertThat(principal.email()).isEqualTo("alice");
        assertThat(principal.roles()).containsExactlyInAnyOrder("USER", "ADMIN");
        assertThat(principal.tokenType()).isEqualTo("access");
        assertThat(svc.parseAndValidateIssuer(token).email()).isEqualTo("alice");
    }

    @Test
    void issuedTokenUsesRs256() {
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        String token = svc.issueAccessToken("alice", Set.of("USER"));

        String header = new String(Base64.getUrlDecoder().decode(token.split("\\.")[0]));

        assertThat(header).contains("\"alg\":\"RS256\"");
    }

    @Test
    void apiTokenHasTypApi() {
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        String token = svc.issueApiToken("service-account", Set.of("ADMIN"));
        AuthPrincipal principal = svc.parse(token);
        assertThat(principal.tokenType()).isEqualTo("api");
        assertThat(principal.email()).isEqualTo("service-account");
        assertThat(principal.roles()).containsExactly("ADMIN");
    }

    @Test
    void tamperedTokenIsRejected() {
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        String token = svc.issueAccessToken("alice", Set.of("USER"));

        // Tamper the payload (the middle base64url segment), not the
        // signature: flipping a payload char always invalidates the
        // signature deterministically, whereas the trailing char of a
        // signature segment only encodes a couple of bits.
        String[] parts = token.split("\\.");
        assertThat(parts).hasSize(3);
        char mid = parts[1].charAt(parts[1].length() / 2);
        String tamperedPayload = parts[1].substring(0, parts[1].length() / 2)
                + (mid == 'A' ? 'B' : 'A')
                + parts[1].substring(parts[1].length() / 2 + 1);
        String tampered = parts[0] + "." + tamperedPayload + "." + parts[2];

        assertThatThrownBy(() -> svc.parse(tampered))
                .isInstanceOf(JwtException.class);
    }

    @Test
    void tokenSignedWithDifferentKeyPairIsRejected() {
        JwtTokenService signer = new JwtTokenService(propsFor(OTHER_KEYS));
        JwtTokenService verifier = new JwtTokenService(DEFAULT_PROPS);

        String token = signer.issueAccessToken("alice", Set.of("USER"));

        assertThatThrownBy(() -> verifier.parse(token))
                .isInstanceOf(JwtException.class);
    }

    @Test
    void verifierWithoutPrivateKeyCanParseButNotIssue() {
        // This is the whole point of moving off HS256: api-gateway,
        // sso-admin and query-service hold the public half only, so a
        // compromise there cannot mint an admin token.
        JwtTokenService issuer = new JwtTokenService(DEFAULT_PROPS);
        JwtTokenService verifier = new JwtTokenService(verifierOnlyProps(KEYS));

        String token = issuer.issueAccessToken("alice", Set.of("ADMIN"));

        assertThat(verifier.parse(token).email()).isEqualTo("alice");
        assertThatThrownBy(() -> verifier.issueAccessToken("mallory", Set.of("ADMIN")))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("sólo para verificar");
    }

    @Test
    void emptyTokenIsRejected() {
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        assertThatThrownBy(() -> svc.parse(""))
                .isInstanceOf(JwtException.class);
        assertThatThrownBy(() -> svc.parse(null))
                .isInstanceOf(JwtException.class);
    }

    @Test
    void acceptsPemWithLiteralBackslashNInsteadOfRealNewlines() {
        // Como llega la clave cuando el PEM viaja en una linea por
        // .env / docker-compose y nadie ha convertido el escape. Se
        // fija porque el sintoma no apunta al origen: el bean falla
        // al arrancar con "no es una clave publica RSA" y parece un
        // problema de la clave, no del transporte.
        String oneLine = pem("PUBLIC KEY", KEYS.getPublic().getEncoded())
                .replace("\n", "\\n");
        assertThat(oneLine).contains("\\n");

        JwtTokenService svc = new JwtTokenService(new JwtProperties(
                pem("PRIVATE KEY", KEYS.getPrivate().getEncoded()).replace("\n", "\\n"),
                oneLine,
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer ",
                GOOD_SECRET));

        String token = svc.issueAccessToken("alice", Set.of("USER"));
        assertThat(svc.parse(token).email()).isEqualTo("alice");
    }

    @Test
    void malformedPublicKeyFailsAtConstruction() {
        // A bad key must break at startup, not on the first request.
        assertThatThrownBy(() -> new JwtTokenService(new JwtProperties(
                null,
                "-----BEGIN PUBLIC KEY-----\nnot-actually-a-key\n-----END PUBLIC KEY-----",
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer ",
                GOOD_SECRET)))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void missingPublicKeyFailsWithActionableMessage() {
        assertThatThrownBy(() -> new JwtTokenService(new JwtProperties(
                null,
                "  ",
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer ",
                GOOD_SECRET)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("gen-jwt-keys.sh");
    }

    @Test
    void validateIssuerRejectsForeignIssuer() {
        // Mint a token with a foreign issuer using OUR private key —
        // a valid signature but the wrong `iss` — and check the strict
        // parser still rejects it.
        String foreignToken = io.jsonwebtoken.Jwts.builder()
                .subject("alice")
                .issuer("evil.example.com")
                .claim("roles", java.util.List.of("ADMIN"))
                .issuedAt(new java.util.Date())
                .expiration(new java.util.Date(System.currentTimeMillis() + 60_000))
                .signWith(KEYS.getPrivate(), io.jsonwebtoken.Jwts.SIG.RS256)
                .compact();

        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);

        // plain parse accepts it (signature is valid, only iss is wrong)
        assertThat(svc.parse(foreignToken).email()).isEqualTo("alice");

        // strict parse rejects
        assertThatThrownBy(() -> svc.parseAndValidateIssuer(foreignToken))
                .isInstanceOf(JwtException.class);
    }

    /* ====================== V29 — uid claim round-trip ====================== */

    @Test
    void roundTripPreservesUidClaim() {
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);

        Set<String> roles = new LinkedHashSet<>();
        roles.add("ADMIN");

        String token = svc.issueAccessToken("alice", 42L, roles);
        AuthPrincipal principal = svc.parse(token);

        assertThat(principal.email()).isEqualTo("alice");
        assertThat(principal.userId()).isEqualTo(42L);
        assertThat(principal.roles()).containsExactly("ADMIN");
        assertThat(principal.tokenType()).isEqualTo("access");
    }

    @Test
    void uidNullAtIssueOmitsClaim() {
        // Back-compat overload: when userId is null, the claim
        // should NOT be in the payload. Tokens without uid parse
        // back to userId=null, which is what the V29 caller
        // (QueryService) treats as "legacy token".
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        String token = svc.issueAccessToken("alice", null, Set.of("USER"));

        AuthPrincipal principal = svc.parse(token);
        assertThat(principal.userId()).isNull();
    }

    @Test
    void tokenWithoutUidClaimParsesToNullUserId() {
        // Forge a token without the uid claim — what callers from
        // before V29 would have produced. Must parse cleanly with
        // userId=null (no NPE).
        SecretKey key = Keys.hmacShaKeyFor(GOOD_SECRET.getBytes(StandardCharsets.UTF_8));
        String legacyToken = io.jsonwebtoken.Jwts.builder()
                .subject("alice")
                .issuer("sso-postgres")
                .claim("roles", java.util.List.of("USER"))
                .claim("typ", "access")
                .issuedAt(new java.util.Date())
                .expiration(new java.util.Date(System.currentTimeMillis() + 60_000))
                .signWith(key, io.jsonwebtoken.Jwts.SIG.HS256)
                .compact();

        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        AuthPrincipal principal = svc.parse(legacyToken);

        assertThat(principal.email()).isEqualTo("alice");
        assertThat(principal.userId()).isNull();
        assertThat(principal.roles()).containsExactly("USER");
    }

    @Test
    void uidClaimAsStringIsParsedAsLong() {
        // Defensive: a non-JJWT producer might emit uid as a JSON
        // string instead of a number. The parser must coerce it.
        SecretKey key = Keys.hmacShaKeyFor(GOOD_SECRET.getBytes(StandardCharsets.UTF_8));
        String oddToken = io.jsonwebtoken.Jwts.builder()
                .subject("alice")
                .issuer("sso-postgres")
                .claim("uid", "99")
                .claim("roles", java.util.List.of("USER"))
                .issuedAt(new java.util.Date())
                .expiration(new java.util.Date(System.currentTimeMillis() + 60_000))
                .signWith(key, io.jsonwebtoken.Jwts.SIG.HS256)
                .compact();

        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        assertThat(svc.parse(oddToken).userId()).isEqualTo(99L);
    }

    @Test
    void uidClaimWithGarbageValueIsRejected() {
        SecretKey key = Keys.hmacShaKeyFor(GOOD_SECRET.getBytes(StandardCharsets.UTF_8));
        String badToken = io.jsonwebtoken.Jwts.builder()
                .subject("alice")
                .issuer("sso-postgres")
                .claim("uid", "not-a-number")
                .claim("roles", java.util.List.of("USER"))
                .issuedAt(new java.util.Date())
                .expiration(new java.util.Date(System.currentTimeMillis() + 60_000))
                .signWith(key, io.jsonwebtoken.Jwts.SIG.HS256)
                .compact();

        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        assertThatThrownBy(() -> svc.parse(badToken))
                .isInstanceOf(JwtException.class)
                .hasMessageContaining("uid");
    }

    @Test
    void backCompatIssueAccessTokenWithoutUidStillWorks() {
        // The (email, roles) overload is kept for callers that
        // haven't migrated. Output must be a valid token and
        // parse to a principal with userId=null.
        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);
        String token = svc.issueAccessToken("alice", Set.of("USER"));
        AuthPrincipal principal = svc.parse(token);
        assertThat(principal.email()).isEqualTo("alice");
        assertThat(principal.userId()).isNull();
    }
}
