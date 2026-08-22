package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.dto.AuthDtos.AppSummary;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Redis-backed {@code @Cacheable} wrapper around {@code GET /myApps}
 * — same family as {@link CachedUserSummaryService}, one cache name
 * per read-mostly lookup.
 *
 * <p>The original call path was two queries per request:
 * {@code roleRepository.findAll()} (filtered in Java against the
 * caller's role names) then {@code appRepository.findVisibleForRoles}.
 * Neither depends on anything per-user beyond the role set itself —
 * two callers with the same effective roles get the exact same
 * answer — so the cache key is the role set, not the caller.
 *
 * <p><b>Why the key is a pre-joined {@code String} and not the
 * {@code Set<String>} itself.</b> Spring's default cache-key
 * serialization calls {@code toString()} on whatever the SpEL key
 * expression evaluates to. A {@link Set}'s {@code toString()} order
 * follows iteration order, which for a {@link LinkedHashSet} tracks
 * insertion order — so the same two roles requested in a different
 * order would miss the cache even though the query result is
 * identical. Sorting + joining into a canonical {@code String} in
 * {@link #rolesCacheKey} before the cache boundary removes that
 * order-sensitivity entirely.
 *
 * <p>TTL comes from {@link SessionCacheProperties#myAppsTtlSeconds()}.
 * Staleness tradeoff mirrors {@code user-by-email}: an admin binding
 * a role to a new app in sso-admin won't show up here until the TTL
 * expires, which is acceptable for a post-login app launcher.
 */
@Service
public class CachedAppAccessService {

    private final RoleRepository roleRepository;
    private final AppRepository appRepository;

    public CachedAppAccessService(RoleRepository roleRepository, AppRepository appRepository) {
        this.roleRepository = roleRepository;
        this.appRepository = appRepository;
    }

    /** Canonical, order-independent cache key for a role set — see class javadoc. */
    public static String rolesCacheKey(Set<String> roleNames) {
        return roleNames.stream().sorted().collect(Collectors.joining(","));
    }

    @Cacheable(value = "my-apps", key = "#rolesKey")
    public List<AppSummary> forRoles(String rolesKey, Set<String> roleNames) {
        Set<Long> roleIds = roleRepository.findAll().stream()
                .filter(r -> roleNames.contains(r.getName()))
                .map(Role::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        if (roleIds.isEmpty()) {
            return List.of();
        }
        return appRepository.findVisibleForRoles(roleIds).stream()
                .map(a -> new AppSummary(a.getId(), a.getName(), a.getDescription(), a.getLaunchUrl()))
                .toList();
    }
}
