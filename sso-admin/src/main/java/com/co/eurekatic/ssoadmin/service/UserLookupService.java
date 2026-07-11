package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Redis-backed projection of {@code UserRepository.findByEmail}
 * that returns just the fields {@code QueryCatalogService}
 * actually needs (a {@link UserRolesView}), instead of pulling
 * the full entity with EAGER roles on every per-row authorization
 * check.
 *
 * <p>{@code QueryCatalogService.listForCaller} fires this lookup
 * for every query row in the catalog (N+1 hit against Postgres
 * before this commit; one Redis hit per email after). The cached
 * shape is immutable + JDK-serializable so the
 * {@code disableCachingNullValues} flag on the cache manager
 * means "user not found" still throws downstream, never a
 * cached null.
 *
 * <p>Cache name is {@code "user-by-email"} — the same name as
 * auth-center's mirror cache. The Redis key namespace doesn't
 * collide (different cache name → different Spring prefix on the
 * Redis side) so the two services can run with the same Redis
 * instance without overwriting each other.
 *
 * <p>Staleness: sso-admin writes to {@code users} /
 * {@code role_users} via {@code UserAdminService}. We rely on
 * the short TTL ({@code AdminAccessProperties.userByEmailCacheTtl},
 * default 60s) to bound staleness. The auth-center mirror of
 * this cache has its own TTL on the auth-center side — the two
 * are independent.
 */
@Service
public class UserLookupService {

    private final UserRepository userRepository;

    public UserLookupService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Cacheable(value = "user-by-email", key = "#email")
    @Transactional(readOnly = true)
    public UserRolesView rolesFor(String email) {
        return userRepository.findByEmail(email)
                .map(u -> new UserRolesView(
                        u.getId(),
                        u.getEmail(),
                        roleNames(u)))
                .orElse(UserRolesView.EMPTY);
    }

    private Set<String> roleNames(User u) {
        return u.getRoles().stream()
                .map(Role::getName)
                .collect(Collectors.toCollection(LinkedHashSet::new));
    }

    /**
     * Stripped-down projection of a User — just the fields
     * {@code QueryCatalogService} consumes (id, email, role set).
     * Avoiding the full entity keeps the cached payload tiny and
     * decouples from {@code User} schema evolution.
     */
    public record UserRolesView(Long id, String email, Set<String> roles)
            implements java.io.Serializable {
        public static final UserRolesView EMPTY = new UserRolesView(null, "", Set.of());

        public boolean hasRole(String name) {
            return roles != null && roles.contains(name);
        }

        public static Optional<UserRolesView> ofNullable(UserRolesView v) {
            return (v == null || v == EMPTY) ? Optional.empty() : Optional.of(v);
        }
    }
}