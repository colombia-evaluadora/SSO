package com.co.eurekatic.ssoadmin.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/**
 * App-scoped access control + sso-admin cache TTL properties.
 * Bound from {@code sso.admin.*} in {@code application.yml}.
 *
 * @param appName              The {@code App.name} row (seeded by the
 *                             V10 migration) that identifies THIS
 *                             console. {@link com.co.eurekatic.ssoadmin.config.SsoAdminAccessManager}
 *                             requires the caller to have a role bound
 *                             (role_app) to this app AND a matching
 *                             role_endpoint binding — ADMIN included,
 *                             no bypass on either check (V15 seeds
 *                             ADMIN with everything, but unbinding a
 *                             specific endpoint from it genuinely
 *                             revokes it). Distinct from {@code
 *                             sso.email.app-name} (branding text for
 *                             outgoing emails).
 * @param appAccessCacheTtl    TTL for the app-access cache
 *                             ({@link com.co.eurekatic.ssoadmin.service.AppAccessService}).
 *                             A safety net for out-of-band DB edits —
 *                             {@code AppService.bindRole}/{@code unbindRole}
 *                             evict the relevant entry immediately on
 *                             write, so this doesn't need to be short.
 * @param rolesCacheTtl        TTL for the {@code "roles"} cache
 *                             backing {@code MyMenuService.roleIdsFromAuth}
 *                             (replaces the per-call {@code roleRepo.findAll()}
 *                             full scan). Roles change rarely, so 5m is
 *                             plenty; {@code RoleAdminService} evicts
 *                             on every CRUD write.
 * @param userByEmailCacheTtl  TTL for the {@code "user-by-email"} cache
 *                             backing {@code QueryCatalogService}
 *                             (replaces the per-query
 *                             {@code userRepo.findByEmail} EAGER load).
 *                             Short (60s) so a disabled user loses
 *                             access quickly; auth-center's mirror of
 *                             the same cache has its own TTL on the
 *                             auth-center side.
 */
@ConfigurationProperties(prefix = "sso.admin")
public record AdminAccessProperties(
        String appName,
        Duration appAccessCacheTtl,
        Duration rolesCacheTtl,
        Duration userByEmailCacheTtl
) {
    public AdminAccessProperties {
        if (appName == null || appName.isBlank()) appName = "SSO-ADMIN";
        if (appAccessCacheTtl == null) appAccessCacheTtl = Duration.ofMinutes(5);
        if (rolesCacheTtl == null) rolesCacheTtl = Duration.ofMinutes(5);
        if (userByEmailCacheTtl == null) userByEmailCacheTtl = Duration.ofSeconds(60);
    }
}
