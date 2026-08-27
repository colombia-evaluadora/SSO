package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.repository.EndpointRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.AntPathMatcher;

import java.util.Set;

/**
 * Resolves whether any of the caller's roles has a {@code role_endpoint}
 * binding for the requested method + path. Backing query is
 * {@link EndpointRepository#findByAnyRoleName}; the method + path
 * match is done in Java because {@code path} may carry Spring-style
 * {@code {var}} segments that can't be pattern-matched in JPQL.
 */
@Service
public class AuthCenterEndpointAccessService {

    private final EndpointRepository endpointRepository;
    private final AntPathMatcher pathMatcher = new AntPathMatcher();

    public AuthCenterEndpointAccessService(EndpointRepository endpointRepository) {
        this.endpointRepository = endpointRepository;
    }

    @Transactional(readOnly = true)
    public boolean hasAccess(String method, String path, Set<String> roleNames) {
        if (roleNames == null || roleNames.isEmpty()) return false;
        return endpointRepository.findByAnyRoleName(roleNames).stream().anyMatch(e ->
                e.getMethod().equalsIgnoreCase(method) && pathMatcher.match(e.getPath(), path));
    }
}
