package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.repository.RoleRepository;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Redis-backed lookup that replaces the per-call
 * {@code roleRepo.findAll()} full scan in
 * {@code MyMenuService.roleIdsFromAuth} (and any other place that
 * needs an authoritative name → id map of every role).
 *
 * <p>{@code MyMenuService.roleIdsFromAuth} is on the hot path of
 * {@code GET /sso-admin/myMenu}: every page load on the admin-ui
 * sidebar hits it. The lookup is tiny in absolute terms (the role
 * table is order-10¹ rows) but Spring caching it removes a
 * guaranteed DB round-trip from a request the SPA fires on every
 * navigation.
 *
 * <p>Cache key is the constant {@code "all"} (no SpEL argument)
 * because the entire role set is the cached unit. Role counts
 * are stable enough that {@code AdminAccessProperties.rolesCacheTtl}
 * (default 5m) plus the explicit eviction in
 * {@code RoleAdminService.createRole / updateRole / deleteRole}
 * is plenty.
 *
 * <p>The cached shape ({@code Map<String, Long>}) is what the
 * callers actually need: name → id, immutable, easily
 * JDK-serializable. Callers that want the full
 * {@link com.co.eurekatic.common.entity.Role Role} entity should
 * hit the repo directly — this service is a hot-path accelerator,
 * not a generic Role cache.
 */
@Service
public class RoleLookupService {

    private final RoleRepository roleRepository;

    public RoleLookupService(RoleRepository roleRepository) {
        this.roleRepository = roleRepository;
    }

    @Cacheable(value = "roles", key = "'all'")
    @Transactional(readOnly = true)
    public Map<String, Long> nameToId() {
        return Map.copyOf(roleRepository.findAll().stream()
                .collect(Collectors.toMap(
                        com.co.eurekatic.common.entity.Role::getName,
                        com.co.eurekatic.common.entity.Role::getId,
                        (a, b) -> a)));
    }

    /**
     * Convenience wrapper that filters the cached map by an
     * allowed-name set and returns the matching ids in insertion
     * order. Avoids the {@code O(roles × names)} in-memory scan
     * pattern that {@code MyMenuService.roleIdsFromAuth} used to
     * do on every {@code /myMenu} call.
     */
    public Map<String, Long> nameToIdFiltered(java.util.Set<String> allowedNames) {
        if (allowedNames == null || allowedNames.isEmpty()) {
            return Map.of();
        }
        return Map.copyOf(nameToId().entrySet().stream()
                .filter(e -> allowedNames.contains(e.getKey()))
                .collect(Collectors.toMap(
                        Map.Entry::getKey,
                        Map.Entry::getValue,
                        (a, b) -> a)));
    }
}