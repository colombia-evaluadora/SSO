package com.co.eurekatic.common.security;

import java.util.Set;

/**
 * Lightweight, immutable view of an authenticated principal extracted from
 * a JWT. Returned by {@link JwtTokenService#parse(String)}; consumed by
 * Spring Security's authentication machinery in the api-gateway filter.
 *
 * @param email     the {@code sub} claim — the user's email, which is the
 *                  unique login identifier since the V12 migration
 *                  (the prior {@code username} column is gone).
 * @param userId    the {@code uid} claim — the numeric
 *                  {@code users.id_user} primary key. Embedded in the JWT
 *                  at issuance so every downstream service has it without
 *                  an extra DB lookup. May be {@code null} for legacy
 *                  tokens minted before the V29 rollout; callers that
 *                  need it (e.g. {@code query-service} injecting
 *                  {@code :caller_user_id}) must tolerate null and decide
 *                  whether to skip the parameter or surface 401.
 * @param roles     the {@code roles} claim (already de-prefixed; e.g. {@code "USER"})
 * @param tokenType "access" or "api"
 */
public record AuthPrincipal(String email, Long userId, Set<String> roles, String tokenType) {

    public AuthPrincipal(String email, Set<String> roles, String tokenType) {
        this(email, null, roles, tokenType);
    }

    public boolean hasRole(String role) {
        return roles != null && roles.contains(role);
    }
}
