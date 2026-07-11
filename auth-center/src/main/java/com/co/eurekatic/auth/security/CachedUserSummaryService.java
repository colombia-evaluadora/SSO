package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.dto.AuthDtos.UserSummary;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.stereotype.Service;

import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Redis-backed {@code @Cacheable} wrapper around the
 * {@code GET /getInfoUser} profile lookup. Caches a serialized
 * {@link UserSummary} under cache name {@code "user-by-email"}
 * so the SPA's "whoami" call doesn't hit Postgres on every page
 * load.
 *
 * <p>The original {@link AuthController#getInfoUser} call path is
 * {@code userRepository.findByEmail(email)} (one query) plus
 * {@code User.roles} EAGER join (one query). With this cache a
 * cache hit returns from Redis with zero Postgres traffic.
 *
 * <p>Failure mode: if the user isn't found we DON'T cache the
 * miss (the underlying {@code @Cacheable} is configured with
 * {@code disableCachingNullValues()} on the cache manager). The
 * upstream {@link AuthController} still throws
 * {@link UsernameNotFoundException} unchanged.
 *
 * <p>Cross-service staleness: admin mutations to {@code users} /
 * {@code role_users} happen in {@code sso-admin}. We rely on the
 * short TTL (default 60s, see
 * {@link SessionCacheProperties#userByEmailTtlSeconds()}) to
 * bound the staleness window instead of building an HTTP
 * invalidation bridge — a disabled user can still complete
 * in-flight requests for up to one minute, which is acceptable
 * given the JWT TTL is one hour.
 *
 * <p>{@link User} is intentionally NOT the cache value. The
 * entity carries DB-coupled fields (token columns, account flags,
 * EAGER role set) that are not safe to deserialize across
 * schema migrations. {@link UserSummary} is the wire contract the
 * SPA expects and is the right boundary to cache.
 */
@Service
public class CachedUserSummaryService {

    private final UserRepository userRepository;

    public CachedUserSummaryService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Cacheable(value = "user-by-email", key = "#email")
    public UserSummary forEmail(String email) {
        User u = userRepository.findByEmail(email)
                .orElseThrow(() -> new UsernameNotFoundException(email));
        return toSummary(u);
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
                .collect(java.util.stream.Collectors.toCollection(LinkedHashSet::new));
    }
}