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
 * @param roles     the {@code roles} claim (already de-prefixed; e.g. {@code "USER"})
 * @param tokenType "access" or "api"
 */
public record AuthPrincipal(String email, Set<String> roles, String tokenType) {

    public boolean hasRole(String role) {
        return roles != null && roles.contains(role);
    }
}
