package com.co.eurekatic.common.security;

import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.security.Keys;
import io.jsonwebtoken.security.WeakKeyException;
import org.junit.jupiter.api.Test;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
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
 *   <li>Secrets shorter than 32 bytes throw {@link WeakKeyException}.</li>
 * </ol>
 */
class JwtTokenServiceTest {

    private static final String GOOD_SECRET =
            "this-is-a-test-secret-that-is-32-bytes-or-longer-1234567890";
    private static final JwtProperties DEFAULT_PROPS = new JwtProperties(
            GOOD_SECRET,
            "sso-postgres",
            3_600L,
            86_400L,
            "Authorization",
            "Bearer ");

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

        // Tamper the payload (the middle base64url segment), not
        // the signature. The signature is 32 bytes (HS256) ->
        // 43 base64url chars, so the last char only encodes the
        // bottom 2 bits of the last byte. Flipping it produces a
        // different but base64-valid signature that *occasionally*
        // the HMAC still rejects; flipping a payload char always
        // breaks the signature, deterministically.
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
    void tokenSignedWithDifferentSecretIsRejected() {
        JwtTokenService signer = new JwtTokenService(DEFAULT_PROPS);
        JwtTokenService verifier = new JwtTokenService(new JwtProperties(
                "another-totally-different-secret-that-is-32-bytes-or-longer",
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer "));

        String token = signer.issueAccessToken("alice", Set.of("USER"));

        assertThatThrownBy(() -> verifier.parse(token))
                .isInstanceOf(JwtException.class);
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
    void secretShorterThan32BytesIsRejected() {
        // 16 bytes is the legacy hardcoded secret's length — must fail.
        // The constructor calls Keys.hmacShaKeyFor(...), which throws
        // WeakKeyException when the key length is below the HS256
        // minimum (256 bits / 32 bytes per RFC 7518 §3.2).
        assertThatThrownBy(() -> new JwtTokenService(new JwtProperties(
                "short-secret-1234",                  // 16 bytes
                "sso-postgres",
                3_600L,
                86_400L,
                "Authorization",
                "Bearer ")))
                .isInstanceOf(WeakKeyException.class);
    }

    @Test
    void validateIssuerRejectsForeignIssuer() {
        // Mint a token with a foreign issuer, then verify the
        // strict parser rejects it.
        SecretKey key = Keys.hmacShaKeyFor(GOOD_SECRET.getBytes(StandardCharsets.UTF_8));
        String foreignToken = io.jsonwebtoken.Jwts.builder()
                .subject("alice")
                .issuer("evil.example.com")
                .claim("roles", java.util.List.of("ADMIN"))
                .issuedAt(new java.util.Date())
                .expiration(new java.util.Date(System.currentTimeMillis() + 60_000))
                .signWith(key, io.jsonwebtoken.Jwts.SIG.HS256)
                .compact();

        JwtTokenService svc = new JwtTokenService(DEFAULT_PROPS);

        // plain parse accepts it (signature is valid, only iss is wrong)
        assertThat(svc.parse(foreignToken).email()).isEqualTo("alice");

        // strict parse rejects
        assertThatThrownBy(() -> svc.parseAndValidateIssuer(foreignToken))
                .isInstanceOf(JwtException.class);
    }
}
