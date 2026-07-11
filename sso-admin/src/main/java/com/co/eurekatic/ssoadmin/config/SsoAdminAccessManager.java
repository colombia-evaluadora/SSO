package com.co.eurekatic.ssoadmin.config;

import com.co.eurekatic.ssoadmin.service.AppAccessService;
import com.co.eurekatic.ssoadmin.service.EndpointAccessService;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.security.authorization.AuthorizationDecision;
import org.springframework.security.authorization.AuthorizationManager;
import org.springframework.security.authorization.AuthorizationResult;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.web.access.intercept.RequestAuthorizationContext;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.function.Supplier;

/**
 * Replaces the bare {@code hasRole("ADMIN")} gate on
 * {@code SecurityConfig}'s {@code anyRequest()} rule.
 *
 * <p>Two checks, in order, and NO bypass for ADMIN on either one:
 * <ol>
 *   <li>at least one of the caller's roles must have a
 *       {@code role_app} binding to {@link #appName} (seeded for
 *       ADMIN by the V10 migration). Without it, {@code role_app}
 *       only ever controlled what {@code /myMenu} shows in the
 *       sidebar; any caller with a role literally named {@code
 *       ADMIN} could reach every business endpoint regardless of
 *       whether that role was ever scoped to this app.</li>
 *   <li>the caller's roles must additionally have a {@code
 *       role_endpoint} binding matching this specific request's
 *       method + path (see {@link EndpointAccessService}). The V15
 *       migration seeds ADMIN with a binding to every endpoint that
 *       exists at seed time, so out of the box this is a no-op for
 *       ADMIN — but unbinding a specific endpoint from ADMIN via
 *       the Endpoints admin screen's Roles tab now genuinely
 *       revokes it, same as for any other role. This is a
 *       deliberate choice, not an oversight: an ADMIN who unbinds
 *       something they need has no bypass to fall back on and must
 *       fix it via that same screen (or the DB) — the alternative
 *       (an unconditional ADMIN bypass) would make the per-endpoint
 *       toggle silently do nothing for the one role most likely to
 *       be testing it.</li>
 * </ol>
 */
public class SsoAdminAccessManager implements AuthorizationManager<RequestAuthorizationContext> {

    private final AppAccessService appAccessService;
    private final EndpointAccessService endpointAccessService;
    private final String appName;

    public SsoAdminAccessManager(AppAccessService appAccessService,
                                  EndpointAccessService endpointAccessService,
                                  String appName) {
        this.appAccessService = appAccessService;
        this.endpointAccessService = endpointAccessService;
        this.appName = appName;
    }

    @Override
    public AuthorizationResult authorize(Supplier<? extends Authentication> authSupplier, RequestAuthorizationContext ctx) {
        Authentication auth = authSupplier.get();
        if (auth == null || !auth.isAuthenticated()) {
            return new AuthorizationDecision(false);
        }

        boolean hasAppAccess = false;
        Set<String> roleNames = new LinkedHashSet<>();
        for (GrantedAuthority authority : auth.getAuthorities()) {
            String roleName = authority.getAuthority().replaceFirst("^ROLE_", "");
            roleNames.add(roleName);
            if (appAccessService.hasAccess(appName, roleName)) {
                hasAppAccess = true;
            }
        }
        if (!hasAppAccess) {
            return new AuthorizationDecision(false);
        }

        HttpServletRequest request = ctx.getRequest();
        boolean hasEndpointAccess =
                endpointAccessService.hasAccess(request.getMethod(), request.getRequestURI(), roleNames);
        return new AuthorizationDecision(hasEndpointAccess);
    }
}
