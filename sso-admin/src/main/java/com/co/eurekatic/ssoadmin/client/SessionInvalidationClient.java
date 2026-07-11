package com.co.eurekatic.ssoadmin.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/**
 * Posts to {@code POST /internal/cache/user-roles/{email}} on
 * auth-center after every role / group binding mutation in
 * sso-admin. Keeps the URL + secret in one place so the affected
 * services don't each hard-code the same {@code RestClient} call.
 *
 * <p>The call is fire-and-log: a failed POST means the affected
 * user's JWT carries stale roles for at most one TTL window
 * (default 1h), then the next login re-reads from the DB. We do
 * NOT want to roll back a successful admin mutation just because
 * the cache-invalidation hop is down.
 *
 * <p>The shared secret is sourced from
 * {@code SSO_SESSION_USER_ROLES_INVALIDATION_SECRET} (env var on
 * both auth-center and sso-admin; Spring relaxed binding maps the
 * property path sso.session.user-roles.invalidation-secret to this
 * canonical env var name). If the env var is empty the client
 * is a no-op — admin mutations still succeed, the cache will
 * heal via TTL. This is a deliberate soft-fail (vs. hard
 * misconfiguration) so an unconfigured dev environment doesn't
 * block admin work.
 */
@Component
public class SessionInvalidationClient {

    private static final Logger log = LoggerFactory.getLogger(SessionInvalidationClient.class);

    /**
     * Header name MUST match the constant in
     * {@code com.co.eurekatic.auth.web.CacheAdminController}. We
     * deliberately don't import that class — sso-admin has no
     * compile-time dependency on auth-center, and the header
     * string is a wire contract, not an API contract.
     */
    static final String SECRET_HEADER = "X-Session-Cache-Secret";

    private final RestClient http;
    private final String secret;

    public SessionInvalidationClient(
            @Value("${sso.auth-center.base-url:http://auth-center:8081}") String baseUrl,
            @Value("${sso.session.user-roles.invalidation-secret:}") String secret) {
        this.http = RestClient.builder().baseUrl(baseUrl).build();
        this.secret = secret;
    }

    /**
     * Invalidates the cached role set for {@code email} on
     * auth-center. No-op if the shared secret is unconfigured.
     */
    public void invalidate(String email) {
        if (email == null || email.isBlank()) {
            return;
        }
        if (secret == null || secret.isBlank()) {
            log.debug("Session cache invalidation skipped (no shared secret configured) email={}", email);
            return;
        }
        try {
            http.post()
                    .uri("/internal/cache/user-roles/{email}", email)
                    .header(SECRET_HEADER, secret)
                    .contentType(MediaType.APPLICATION_JSON)
                    .retrieve()
                    .toBodilessEntity();
            log.debug("User-roles cache invalidated on auth-center email={}", email);
        } catch (RuntimeException e) {
            // Best-effort. The admin mutation has already committed
            // to the local DB; the worst case is a stale role set
            // for this user for one TTL window.
            log.warn("Failed to invalidate user-roles cache on auth-center email={}", email, e);
        }
    }
}