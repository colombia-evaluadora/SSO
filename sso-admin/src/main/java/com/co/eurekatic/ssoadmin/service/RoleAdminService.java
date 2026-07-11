package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.dto.RoleRequest;
import com.co.eurekatic.ssoadmin.dto.RoleResponse;
import com.co.eurekatic.ssoadmin.dto.UserResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Role CRUD and bindings. The legacy
 * {@code com.co.lowcode.sso.service.RoleService} mixed in
 * endpoint/route bindings (Phase 2) — Phase 1 only handles
 * user↔role bindings, which is the only binding table that
 * exists in the schema today.
 *
 * <p>Cache coupling: every write here invalidates the
 * {@code "roles"} Redis cache (the name → id map
 * {@code MyMenuService.roleIdsFromAuth} consumes via
 * {@link RoleLookupService}). The TTL on that cache is 5m by
 * default ({@code sso.admin.roles-cache-ttl}); eviction makes
 * the new state visible immediately on the next read.
 */
@Service
public class RoleAdminService {

    /**
     * The legacy {@code RoleService.getRolesOwn} excluded this
     * role from the "operational admin" view. We keep the same
     * behavior — the "regular admin" UI shows the roles they
     * can grant, minus the system-level admin role.
     */
    static final String EXCLUDED_FROM_OWN_VIEW = "ADMIN_USUARIOS_OPERADORAS";

    private final RoleRepository roleRepository;
    private final UserRepository userRepository;
    private final CacheManager cacheManager;

    public RoleAdminService(RoleRepository roleRepository,
                            UserRepository userRepository,
                            CacheManager cacheManager) {
        this.roleRepository = roleRepository;
        this.userRepository = userRepository;
        this.cacheManager = cacheManager;
    }

    @Transactional
    public RoleResponse createRole(RoleRequest req) {
        if (roleRepository.existsByName(req.name())) {
            throw new IllegalArgumentException("Role already exists: " + req.name());
        }
        Role role = new Role(req.name(), req.description());
        RoleResponse response = RoleResponse.fromEntity(roleRepository.save(role));
        evictRolesCache();
        return response;
    }

    @Transactional
    public RoleResponse updateRole(RoleRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        Role role = roleRepository.findById(req.id())
                .orElseThrow(() -> new NotFoundException("Role", req.id()));
        role.setName(req.name());
        role.setDescription(req.description());
        RoleResponse response = RoleResponse.fromEntity(roleRepository.save(role));
        evictRolesCache();
        return response;
    }

    @Transactional(readOnly = true)
    public List<RoleResponse> getRoles() {
        return roleRepository.findAll().stream()
                .map(RoleResponse::fromEntity)
                .toList();
    }

    /**
     * Same as {@link #getRoles} but excludes the
     * {@link #EXCLUDED_FROM_OWN_VIEW} role.
     */
    @Transactional(readOnly = true)
    public List<RoleResponse> getRolesOwn() {
        return roleRepository.findAll().stream()
                .filter(r -> !EXCLUDED_FROM_OWN_VIEW.equals(r.getName()))
                .map(RoleResponse::fromEntity)
                .toList();
    }

    /**
     * Returns the users that have the given role.
     */
    @Transactional(readOnly = true)
    public List<UserResponse> getUsersForRole(Long roleId) {
        Role role = roleRepository.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        Set<User> users = role.getUsers();
        return users.stream().map(UserResponse::fromEntity).toList();
    }

    /**
     * Returns ALL users, with a {@code checked} flag indicating
     * whether each user has the given role. Used to render the
     * "edit users in this role" multi-select UI.
     */
    @Transactional(readOnly = true)
    public List<UserRoleChecked> getUsersForRoleChecked(Long roleId) {
        Role role = roleRepository.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        Set<Long> memberIds = role.getUsers().stream()
                .map(User::getId)
                .collect(Collectors.toSet());
        return userRepository.findAll().stream()
                .map(u -> new UserRoleChecked(
                        u.getId(),
                        u.getEmail(),
                        u.getFullName(),
                        memberIds.contains(u.getId())))
                .toList();
    }

    /**
     * Drops the {@code "roles"} Redis cache so the next
     * {@code MyMenuService} read picks up the new role set.
     * Key shape doesn't matter — the cache holds the full map
     * under one entry — so a single {@code clear()} is correct.
     */
    private void evictRolesCache() {
        Cache cache = cacheManager.getCache("roles");
        if (cache != null) {
            cache.clear();
        }
    }

    /**
     * Per-role checked-listing of users. The {@code username} slot
     * was removed in the V12 migration — the field is bound to
     * {@code email} (the login identifier; see {@code getEmail()}
     * on the {@code User} entity). Field order matches the
     * {@code UserRoleChecked} TS type in
     * {@code admin-ui/src/api/types.ts}.
     */
    public record UserRoleChecked(Long userId, String email, String fullName, boolean checked) {}
}
