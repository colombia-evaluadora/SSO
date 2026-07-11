package com.co.eurekatic.auth.security;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Configuration for the Redis-backed cache of
 * {@link EffectiveRolesResolver#forEmail(String)} results. Bound from
 * {@code sso.session.user-roles.*}.
 *
 * <p>The TTL is set to {@link #DEFAULT_TTL_SECONDS} (one hour) by
 * design — it matches the access-token lifetime so a fresh login
 * re-reads roles and any subsequent request within that window
 * reads the cached set. The tradeoff is that role bindings changed
 * by an admin in sso-admin will not be visible to a still-live
 * access token for up to one hour; admin services therefore MUST
 * hit {@code POST /internal/cache/user-roles/{email}} after every
 * role / group binding mutation (see
 * {@link com.co.eurekatic.ssoadmin.client.SessionInvalidationClient}).
 *
 * <p>{@link #keyPrefix()} namespaces Redis keys so multiple SSO
 * deployments can share a single Redis instance for testing or
 * staging. Unlike {@link RefreshTokenProperties}, this prefix does
 * not need to be coupled to a cookie name — the cache key is
 * derived from the user's email, not a wire credential.
 *
 * <p>{@link #invalidationSecret()} gates the
 * {@code POST /internal/cache/user-roles/{email}} endpoint. Set
 * {@code SSO_SESSION_USER_ROLES_INVALIDATION_SECRET} in every
 * environment — if absent the endpoint rejects every request,
 * which is the intended fail-closed posture.
 *
 * <p>{@link #enabled} exists for tests; production should leave
 * it {@code true}. Turning it off bypasses Redis entirely and
 * delegates straight to the wrapped resolver.
 */
@Validated
@ConfigurationProperties(prefix = "sso.session.user-roles")
public record SessionCacheProperties(
        @Min(60) long ttlSeconds,
        @NotBlank String keyPrefix,
        String invalidationSecret,
        boolean enabled,
        @Min(10) long userByEmailTtlSeconds) {

    /** One hour — matches {@code sso.jwt.access-token-ttl-seconds}. */
    public static final long DEFAULT_TTL_SECONDS = 3600L;

    /** Short TTL for the {@code user-by-email} @Cacheable profile lookup. */
    public static final long DEFAULT_USER_BY_EMAIL_TTL_SECONDS = 60L;

    public static final String DEFAULT_KEY_PREFIX = "sso:session:user-roles";

    public SessionCacheProperties {
        if (ttlSeconds <= 0) {
            ttlSeconds = DEFAULT_TTL_SECONDS;
        }
        if (userByEmailTtlSeconds <= 0) {
            userByEmailTtlSeconds = DEFAULT_USER_BY_EMAIL_TTL_SECONDS;
        }
        if (keyPrefix == null || keyPrefix.isBlank()) {
            keyPrefix = DEFAULT_KEY_PREFIX;
        }
        if (invalidationSecret == null) {
            // Empty is the documented "no shared secret configured"
            // state — the controller rejects every request when
            // this is blank. Not @NotBlank because the default
            // ${SSO_SESSION_USER_ROLES_INVALIDATION_SECRET:} is empty in dev,
            // and we don't want to block startup over that.
            invalidationSecret = "";
        }
    }
}