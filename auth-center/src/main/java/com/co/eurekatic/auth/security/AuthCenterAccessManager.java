package com.co.eurekatic.auth.security;

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
 * Per-request authorization for auth-center's protected routes.
 * Delegates the role-vs-endpoint intersection to
 * {@link AuthCenterEndpointAccessService}; no built-in bypass for any
 * role, so an admin revoking a binding via sso-admin's Endpoints
 * screen takes effect immediately.
 */
public class AuthCenterAccessManager implements AuthorizationManager<RequestAuthorizationContext> {

    private final AuthCenterEndpointAccessService endpointAccess;

    public AuthCenterAccessManager(AuthCenterEndpointAccessService endpointAccess) {
        this.endpointAccess = endpointAccess;
    }

    @Override
    public AuthorizationResult authorize(Supplier<? extends Authentication> authSupplier,
                                          RequestAuthorizationContext ctx) {
        Authentication auth = authSupplier.get();
        if (auth == null || !auth.isAuthenticated()) {
            return new AuthorizationDecision(false);
        }
        Set<String> roleNames = new LinkedHashSet<>();
        for (GrantedAuthority ga : auth.getAuthorities()) {
            String name = ga.getAuthority();
            if (name != null && !name.isBlank()) roleNames.add(name);
        }
        HttpServletRequest request = ctx.getRequest();
        return new AuthorizationDecision(
                endpointAccess.hasAccess(request.getMethod(), request.getRequestURI(), roleNames));
    }
}
