package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.RouteRepository;
import com.co.eurekatic.ssoadmin.dto.RouteResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Resolves the per-user sidebar menu from the JWT authorities.
 *
 * <p>The endpoint {@code GET /sso-admin/myMenu} consumes this
 * service; the frontend then renders the sidebar from the
 * returned routes.
 *
 * <p><b>{@code role_route} is the sole grant for menu
 * visibility</b> — a route shows up for a caller if and only if
 * one of their roles has a direct {@code role_route} binding to
 * it (see {@link RouteRepository#findVisibleForRoles}). {@code
 * role_app} answers a different question entirely — "can this
 * role use this app at all" (see {@code SsoAdminAccessManager})
 * — and does NOT by itself grant menu visibility; a role with
 * app-level access still only sees the routes it's explicitly
 * {@code role_route}-bound to. This used to be a broad-OR-fine
 * union (any role with {@code role_app} access saw every {@code
 * app_route}-bound route in that app, regardless of {@code
 * role_route}), which made the Route edit page's Roles tab a
 * no-op for such a role — unbinding one specific route did
 * nothing because the app-level grant still applied. Removed.
 *
 * <p>JWT authorities come back as {@code ROLE_<NAME>} (see
 * {@link com.co.eurekatic.ssoadmin.config.JwtAuthenticationFilter}).
 * We strip the prefix to look up the {@link com.co.eurekatic.common.entity.Role Role}
 * entity by {@code name}, which is the authority stored in
 * {@code auth-center}'s JWT claims.
 *
 * <p>Optional scoping by app name: {@link #forCaller(Authentication, String)}
 * intersects the {@code role_route}-granted set with routes that
 * are members (via {@code app_route}) of the resolved
 * {@link App} — narrowing, never granting. The SPA bakes
 * {@code VITE_APP_NAME} at build time and forwards it via
 * {@code ?app=...}; multi-tenant edits or any "show all my
 * menus" use-case call the un-scoped {@link #forCaller(Authentication)}
 * instead.
 */
@Service
public class MyMenuService {

    private final RouteRepository routeRepo;
    private final RoleLookupService roleLookup;
    private final AppRepository appRepo;

    public MyMenuService(RouteRepository routeRepo,
                         RoleLookupService roleLookup,
                         AppRepository appRepo) {
        this.routeRepo = routeRepo;
        this.roleLookup = roleLookup;
        this.appRepo = appRepo;
    }

    /**
     * Returns every route visible to the caller. Empty list is a
     * legitimate answer (the user has roles, but none of them
     * have a {@code role_route} binding to any route — admin
     * should investigate missing bindings on the Route edit
     * page's Roles tab).
     */
    @Transactional(readOnly = true)
    public List<RouteResponse> forCaller(Authentication auth) {
        Set<Long> roleIds = roleIdsFromAuth(auth);
        if (roleIds.isEmpty()) {
            return List.of();
        }
        return routeRepo.findVisibleForRoles(roleIds).stream()
                .map(RouteResponse::fromEntity)
                .toList();
    }

    /**
     * Returns the routes visible to the caller that ALSO belong
     * to the named {@link App}. Used by the SPA when it has a
     * {@code VITE_APP_NAME} baked at build time — the SPA then
     * sees only the menu of its own app, never the menus of
     * other apps the same user might be entitled to.
     *
     * <p>Short-circuits (return {@code List.of()}, never throw):
     * <ul>
     *   <li>{@code appName} is null — caller didn't scope
     *       (clients that haven't migrated yet; preserves
     *       backwards-compat semantics — except we don't fall
     *       through to the un-scoped query here, callers wanting
     *       the union call the 1-arg overload).</li>
     *   <li>{@code appName} is blank after trim — same as null.</li>
     *   <li>No {@link App} row with that exact name (case-sensitive;
     *       {@code app.name} is {@code UNIQUE NOT NULL} per
     *       {@link com.co.eurekatic.common.entity.App}).</li>
     *   <li>Caller's role set is empty (not logged in with
     *       any recognized authority).</li>
     * </ul>
     * All four collapse to {@code 200 + []} on the wire, which
     * is consistent with {@link #forCaller(Authentication)}'s
     * "empty list is a legitimate answer" contract — the
     * endpoint answers "what can I see?", and "nothing" is
     * always a 200.
     */
    @Transactional(readOnly = true)
    public List<RouteResponse> forCaller(Authentication auth, String appName) {
        Set<Long> roleIds = roleIdsFromAuth(auth);
        if (roleIds.isEmpty()) {
            return List.of();
        }
        String trimmed = appName == null ? null : appName.trim();
        if (trimmed == null || trimmed.isEmpty()) {
            return List.of();
        }
        Long appId = appRepo.findByName(trimmed).map(app -> app.getId()).orElse(null);
        if (appId == null) {
            return List.of();
        }
        return routeRepo.findVisibleForRoles(roleIds, appId).stream()
                .map(RouteResponse::fromEntity)
                .toList();
    }

    /**
     * Maps {@code ROLE_<NAME>} authorities to role ids by
     * name. The lookup goes through {@link RoleLookupService},
     * which caches the full name → id map under Redis
     * {@code "roles"} so this method no longer triggers a
     * {@code roleRepo.findAll()} full scan on every
     * {@code /myMenu} call.
     */
    private Set<Long> roleIdsFromAuth(Authentication auth) {
        if (auth == null) return Set.of();
        Set<String> names = new LinkedHashSet<>();
        for (GrantedAuthority ga : auth.getAuthorities()) {
            String a = ga.getAuthority();
            if (a != null && a.startsWith("ROLE_")) {
                names.add(a.substring("ROLE_".length()));
            }
        }
        if (names.isEmpty()) return Set.of();
        Map<String, Long> allRoles = roleLookup.nameToId();
        Set<Long> ids = new LinkedHashSet<>();
        for (String name : names) {
            Long id = allRoles.get(name);
            if (id != null) {
                ids.add(id);
            }
        }
        return ids;
    }
}