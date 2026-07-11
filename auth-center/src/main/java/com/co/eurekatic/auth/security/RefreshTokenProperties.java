package com.co.eurekatic.auth.security;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Configuration for the Redis-backed refresh-token store. Bound
 * from {@code sso.refresh-token.*}.
 *
 * <p>{@link #ttlSeconds()} is the lifetime of every refresh token
 * minted through the store. The value is mirrored to the cookie's
 * {@code Max-Age} attribute so the browser and the store agree on
 * when the token expires.
 *
 * <p>{@link #keyPrefix()} namespaces Redis keys so multiple SSO
 * deployments can share a single Redis instance for testing or
 * staging. <strong>Important</strong>: the prefix MUST stay
 * coupled to the cookie name {@code sso_refresh} defined in
 * {@code JsonLoginFilter}. If the cookie name ever changes, the
 * prefix must change too — otherwise a stale cookie from a
 * previous deployment could be replayed.
 */
@Validated
@ConfigurationProperties(prefix = "sso.refresh-token")
public record RefreshTokenProperties(
        @Min(60) long ttlSeconds,
        @NotBlank String keyPrefix,
        boolean failOpen) {

    /** 30 days — RFC 9700 §4.14 allows longer than access-token TTL but caps at "session length". */
    public static final long DEFAULT_TTL_SECONDS = 30L * 24 * 60 * 60;

    public static final String DEFAULT_KEY_PREFIX = "sso:refresh";

    public RefreshTokenProperties {
        if (ttlSeconds <= 0) {
            ttlSeconds = DEFAULT_TTL_SECONDS;
        }
        if (keyPrefix == null || keyPrefix.isBlank()) {
            keyPrefix = DEFAULT_KEY_PREFIX;
        }
        // failOpen defaults to false at the call site (the boolean
        // field is primitive; Spring binds it to the configured value).
    }
}