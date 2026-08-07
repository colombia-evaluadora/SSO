package com.co.eurekatic.common.security;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Strongly-typed configuration for the JWT subsystem. Bound from
 * {@code sso.jwt.*} properties by Spring Boot. Used by both the
 * issuer (auth-center) and the validators (api-gateway, sso-admin,
 * query-service).
 *
 * <p><b>RS256 (asymmetric).</b> The tokens are signed with an RSA
 * private key and verified with the matching public key. Only
 * auth-center gets {@link #privateKey()}; every other service is
 * configured with {@link #publicKey()} alone and is therefore
 * structurally incapable of minting a token. Under the previous
 * HS256 setup a single {@code JWT_SECRET} was shared by all five
 * services, so a read-only verifier that got compromised could
 * forge an admin token — that is the asymmetry this buys.
 *
 * <p>Both fields hold a PEM document (the whole thing, including
 * the {@code -----BEGIN ...-----} armor). {@code privateKey} must
 * be PKCS#8 ({@code BEGIN PRIVATE KEY}) and {@code publicKey}
 * X.509/SPKI ({@code BEGIN PUBLIC KEY}) — the formats
 * {@code scripts/gen-jwt-keys.sh} emits.
 *
 * <p>{@code privateKey} is nullable on purpose: a verifier-only
 * service leaves it unset. Neither key has a placeholder default —
 * there is no safe stand-in for a signing key, and a service that
 * boots with a key nobody controls is worse than one that refuses
 * to boot. {@link JwtTokenService} fails fast with a readable
 * message when the PEM is missing or malformed.
 */
@Validated
@ConfigurationProperties(prefix = "sso.jwt")
public record JwtProperties(
        String privateKey,
        @NotBlank String publicKey,
        @NotBlank String issuer,
        @Min(60) long accessTokenTtlSeconds,
        @Min(60) long apiTokenTtlSeconds,
        @NotBlank String headerName,
        @NotBlank String tokenPrefix,
        // V29 — HS256 fallback for services that prefer
        // symmetric signing. Nullable; when {@link #privateKey}
        // is set, the service uses RS256 and this field is
        // ignored. Most prod deployments use RS256 (test branch
        // default); main's HMAC path remains valid for dev
        // environments where a single shared secret is fine.
        //
        // Declared LAST so existing test constructors that
        // pass the original 7 args still compile. New callers
        // can pass an 8th arg for HS256.
        String secret) {

    public static final String DEFAULT_ISSUER = "sso-postgres";
    public static final String DEFAULT_HEADER = "Authorization";
    public static final String DEFAULT_PREFIX = "Bearer ";

    /**
     * Compact constructor with sensible defaults so partial configuration
     * works (e.g. {@code sso.jwt.public-key=...} alone on a verifier).
     */
    public JwtProperties {
        if (issuer == null || issuer.isBlank()) {
            issuer = DEFAULT_ISSUER;
        }
        if (accessTokenTtlSeconds <= 0) {
            accessTokenTtlSeconds = 3_600L;            // 1 hour
        }
        if (apiTokenTtlSeconds <= 0) {
            apiTokenTtlSeconds = 86_400L;              // 24 hours
        }
        if (headerName == null || headerName.isBlank()) {
            headerName = DEFAULT_HEADER;
        }
        if (tokenPrefix == null || tokenPrefix.isBlank()) {
            tokenPrefix = DEFAULT_PREFIX;
        }
    }

    /** True when this service is configured to sign, not just verify. */
    public boolean canIssue() {
        return (privateKey != null && !privateKey.isBlank())
                || (secret != null && !secret.isBlank());
    }
}
