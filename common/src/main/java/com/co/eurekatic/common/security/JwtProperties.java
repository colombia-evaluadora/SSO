package com.co.eurekatic.common.security;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Strongly-typed configuration for the JWT subsystem. Bound from
 * {@code sso.jwt.*} properties by Spring Boot. Used by both the
 * issuer (auth-center) and the validator (api-gateway).
 *
 * <p>Defaults are deliberately safe and a 64-character placeholder is
 * supplied so the application starts even without an explicit
 * {@code JWT_SECRET} env var. Production deployments MUST override
 * the secret via environment variable — the default is in the
 * code so dev environments work, not so prod can rely on it.
 *
 * <p>The secret must be at least 32 bytes (256 bits) — HS256 requires
 * a key that long. The {@code issueAccessToken} call will throw a
 * {@code WeakKeyException} if the configured secret is too short.
 */
@Validated
@ConfigurationProperties(prefix = "sso.jwt")
public record JwtProperties(
        @NotBlank String secret,
        @NotBlank String issuer,
        @Min(60) long accessTokenTtlSeconds,
        @Min(60) long apiTokenTtlSeconds,
        @NotBlank String headerName,
        @NotBlank String tokenPrefix) {

    /**
     * A 64-character placeholder. NOT FOR PRODUCTION. Override via
     * {@code JWT_SECRET} env var or {@code sso.jwt.secret} property.
     */
    public static final String DEFAULT_SECRET =
            "change-me-change-me-change-me-change-me-change-me-1234567890";

    public static final String DEFAULT_ISSUER = "sso-postgres";
    public static final String DEFAULT_HEADER = "Authorization";
    public static final String DEFAULT_PREFIX = "Bearer ";

    /**
     * Compact constructor with sensible defaults so partial configuration
     * works (e.g. {@code sso.jwt.secret=...} alone).
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
}
