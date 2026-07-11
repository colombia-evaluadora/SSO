package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Endpoint;
import com.co.eurekatic.common.repository.EndpointRepository;
import org.springframework.stereotype.Service;
import org.springframework.util.AntPathMatcher;

import java.util.Collection;
import java.util.List;

/**
 * Answers "can any of these roles invoke METHOD PATH?", backed by
 * {@code role_endpoint}. Used by {@code SsoAdminAccessManager} to
 * gate every sso-admin business endpoint for non-ADMIN callers
 * (ADMIN bypasses this entirely — see its Javadoc).
 *
 * <p>No caching (unlike {@link AppAccessService}'s per-app Redis
 * cache): the catalog is ~100 rows total, and a request's role set
 * is typically 1-2 roles, so {@link EndpointRepository#findByAnyRoleName}
 * returns a handful of rows to pattern-match in memory — trivial
 * cost per request. Add a cache here (same Redis pattern, invalidated
 * on {@code EndpointService.bindRole}/{@code unbindRole}) if this
 * ever shows up as a hot path.
 *
 * <p>{@code endpoint.path} may contain Spring-style {@code {var}}
 * segments (e.g. {@code /role/{id}}); {@link AntPathMatcher}
 * understands that syntax the same way Spring MVC's own request
 * mapping does, so {@code /role/{id}} matches an incoming
 * {@code /role/42}.
 */
@Service
public class EndpointAccessService {

    private final EndpointRepository endpointRepository;
    private final AntPathMatcher pathMatcher = new AntPathMatcher();

    public EndpointAccessService(EndpointRepository endpointRepository) {
        this.endpointRepository = endpointRepository;
    }

    public boolean hasAccess(String method, String path, Collection<String> roleNames) {
        if (roleNames.isEmpty()) {
            return false;
        }
        List<Endpoint> candidates = endpointRepository.findByAnyRoleName(roleNames);
        for (Endpoint e : candidates) {
            if (e.getMethod().equalsIgnoreCase(method) && pathMatcher.match(e.getPath(), path)) {
                return true;
            }
        }
        return false;
    }
}
