package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.dto.AuthDtos.UserSummary;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Redis-backed {@code @Cacheable} wrapper around {@code GET
 * /getUsersSSO} — same family as {@link CachedUserSummaryService}
 * and {@link CachedAppAccessService}. Unlike those two, there is no
 * key: the endpoint always returns the full enabled-user list, so
 * the cache holds a single entry under {@code "users-sso"}.
 *
 * <p>TTL comes from
 * {@link SessionCacheProperties#usersSsoTtlSeconds()} — kept short
 * (see {@code application.yml}) because a newly-registered user
 * should show up in listings without waiting out a long window.
 */
@Service
public class CachedUserListService {

    @PersistenceContext
    private EntityManager em;

    @Cacheable("users-sso")
    @Transactional(readOnly = true)
    public List<UserSummary> allEnabled() {
        // Una sola consulta con los roles traidos por JOIN FETCH: findAll()
        // con roles EAGER dispara 1 + N selects.
        return em.createQuery(
                        "select distinct u from User u left join fetch u.roles", User.class)
                .getResultList().stream()
                .filter(User::isEnabled)
                .map(this::toSummary)
                .collect(Collectors.toList());
    }

    private UserSummary toSummary(User u) {
        return new UserSummary(
                u.getId(),
                u.getEmail(),
                u.getFullName(),
                u.isEnabled(),
                u.isLdap(),
                roleNames(u));
    }

    private Set<String> roleNames(User u) {
        return u.getRoles().stream()
                .map(Role::getName)
                .collect(Collectors.toCollection(LinkedHashSet::new));
    }
}
