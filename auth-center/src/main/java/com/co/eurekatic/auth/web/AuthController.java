package com.co.eurekatic.auth.web;

import com.co.eurekatic.auth.security.CachedUserSummaryService;
import com.co.eurekatic.auth.security.EffectiveRolesResolver;
import com.co.eurekatic.common.dto.AuthDtos.AppSummary;
import com.co.eurekatic.common.dto.AuthDtos.UserSummary;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtTokenService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * REST endpoints exposed by auth-center. POST /login is NOT in this
 * controller — it's handled by {@link JsonLoginFilter} which sets
 * the response body directly. Everything here is a GET.
 */
@RestController
@RequestMapping
public class AuthController {

    private final UserRepository userRepository;
    private final RoleRepository roleRepository;
    private final AppRepository appRepository;
    private final JwtTokenService jwt;
    private final EffectiveRolesResolver effectiveRoles;
    private final CachedUserSummaryService cachedUserSummary;

    public AuthController(UserRepository userRepository, RoleRepository roleRepository,
                           AppRepository appRepository, JwtTokenService jwt,
                           EffectiveRolesResolver effectiveRoles,
                           CachedUserSummaryService cachedUserSummary) {
        this.userRepository = userRepository;
        this.roleRepository = roleRepository;
        this.appRepository = appRepository;
        this.jwt = jwt;
        this.effectiveRoles = effectiveRoles;
        this.cachedUserSummary = cachedUserSummary;
    }

    /**
     * Service-to-service login. The {@code apiToken} is a long-lived
     * credential bound to a user; on success we issue an access token
     * marked {@code typ=api}.
     *
     * <p><b>About a previous endpoint that lived here:</b> {@code GET
     * /getToken?refreshToken=…} was an MVP placeholder that accepted
     * any non-empty {@code refreshToken} and re-issued an access token
     * for the bearer of the {@code Authorization} header. The
     * {@code refreshToken} parameter was decorative — it was neither
     * validated against any store nor rotated. Removal motivation is
     * documented in the security note in the project README.
     * Clients that actually need to rotate a refresh token use
     * {@code POST /api/auth/refresh} (or {@code POST /auth/refresh}
     * via the api-gateway), which is backed by
     * {@code RefreshTokenStore.rotate} with full RFC 9700 §4.14
     * family revocation.
     */
    @GetMapping("/getApiToken")
    public ResponseEntity<?> getApiToken(@RequestParam("apiToken") String apiToken) {
        User user = userRepository.findByApiToken(apiToken)
                .orElseThrow(() -> new AccessDeniedException("Unknown apiToken"));
        if (!user.isEnabled()) {
            throw new AccessDeniedException("User is disabled");
        }
        Set<String> roles = effectiveRoles.forEmail(user.getEmail());
        return ResponseEntity.ok(new com.co.eurekatic.common.dto.AuthDtos.TokenResponse(
                jwt.issueApiToken(user.getEmail(), roles),
                user.getApiToken(),
                86_400L));
    }

    /**
     * Returns the authenticated user's profile. Requires a valid Bearer
     * token (the {@link JwtAuthenticationFilter} populates the
     * SecurityContext from the token).
     *
     * <p>Profile fetch is served from {@code CachedUserSummaryService}
     * (Redis-backed {@code @Cacheable("user-by-email")}) so the SPA
     * does not hit Postgres on every page load. See
     * {@link CachedUserSummaryService} for the staleness tradeoff.
     */
    @GetMapping("/getInfoUser")
    public ResponseEntity<UserSummary> getInfoUser(Authentication authentication) {
        String email = principalName(authentication);
        return ResponseEntity.ok(cachedUserSummary.forEmail(email));
    }

    /**
     * Apps the caller's roles have a {@code role_app} binding to —
     * powers admin-ui's post-login launcher (0 or 1 apps: skip the
     * picker and go straight in; 2+: let the user choose). Not
     * gated to any particular app or authority, unlike sso-admin's
     * endpoints — this is shared, app-agnostic infrastructure, the
     * same category as {@link #getInfoUser}.
     *
     * <p>Role ids come from the JWT's granted authorities (the
     * session's effective role set, group memberships included),
     * not a fresh DB lookup of the user's direct roles — see
     * {@link #roleNamesFromAuthorities} for why no prefix-stripping
     * happens here, unlike sso-admin's equivalent. Reading off the
     * JWT (rather than {@code User.getRoles()}) reflects exactly
     * the role set already governing {@code role_app}/{@code
     * role_route} elsewhere.
     */
    @GetMapping("/myApps")
    public ResponseEntity<List<AppSummary>> myApps(Authentication authentication) {
        Set<String> roleNames = roleNamesFromAuthorities(authentication);
        if (roleNames.isEmpty()) {
            return ResponseEntity.ok(List.of());
        }
        Set<Long> roleIds = roleRepository.findAll().stream()
                .filter(r -> roleNames.contains(r.getName()))
                .map(Role::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        if (roleIds.isEmpty()) {
            return ResponseEntity.ok(List.of());
        }
        List<AppSummary> out = appRepository.findVisibleForRoles(roleIds).stream()
                .map(a -> new AppSummary(a.getId(), a.getName(), a.getDescription(), a.getLaunchUrl()))
                .toList();
        return ResponseEntity.ok(out);
    }

    /**
     * Lists the active users in the system. Permit-all in the MVP
     * because the legacy endpoint was also unauthenticated; in
     * production this should be gated to {@code ADMIN}.
     */
    @GetMapping("/getUsersSSO")
    public ResponseEntity<List<UserSummary>> getUsersSSO() {
        List<UserSummary> out = userRepository.findAll().stream()
                .filter(User::isEnabled)
                .map(this::toSummary)
                .collect(Collectors.toList());
        return ResponseEntity.ok(out);
    }

    /* ====================== helpers ====================== */

    /**
     * Pulls the email off the {@link Authentication} regardless of
     * whether the principal is a {@link User} entity (login flow) or
     * an {@link AuthPrincipal} record (token-bearer flow). Email is
     * the unique login identifier since the V12 migration.
     */
    private String principalName(Authentication authentication) {
        if (authentication == null || authentication.getPrincipal() == null) {
            throw new AccessDeniedException("Missing authentication");
        }
        Object p = authentication.getPrincipal();
        if (p instanceof User u) return u.getEmail();
        if (p instanceof AuthPrincipal ap) return ap.email();
        return authentication.getName();
    }

    /**
     * The session's effective role names off the JWT's granted
     * authorities. Unlike sso-admin's JWT filter (which prefixes
     * {@code ROLE_}, stripped by {@code MyMenuService
     * .roleIdsFromAuth}), auth-center's own {@link
     * com.co.eurekatic.auth.security.JwtAuthenticationFilter} builds
     * authorities as bare role names ({@code new
     * SimpleGrantedAuthority(roleName)} straight off the JWT's
     * {@code roles} claim — see {@code .hasAuthority("ADMIN")} on
     * {@code /getUsersSSO} for the same bare-name convention), so
     * no prefix-stripping happens here.
     */
    private Set<String> roleNamesFromAuthorities(Authentication authentication) {
        if (authentication == null) return Set.of();
        Set<String> names = new LinkedHashSet<>();
        for (GrantedAuthority ga : authentication.getAuthorities()) {
            String a = ga.getAuthority();
            if (a != null && !a.isBlank()) {
                names.add(a);
            }
        }
        return names;
    }

    private Set<String> roleNames(User u) {
        return u.getRoles().stream()
                .map(Role::getName)
                .collect(Collectors.toCollection(LinkedHashSet::new));
    }

    /**
     * {@link UserSummary#roles()} intentionally still reflects only
     * the user's DIRECT roles (via {@link #roleNames(User)}), not
     * the group-effective set — this summary is a profile view, not
     * a token-issuing path, so it's left as-is. The
     * {@code username} slot was removed in the V12 migration; email
     * IS the unique login identifier.
     */
    private UserSummary toSummary(User u) {
        return new UserSummary(
                u.getId(),
                u.getEmail(),
                u.getFullName(),
                u.isEnabled(),
                u.isLdap(),
                roleNames(u));
    }
}
