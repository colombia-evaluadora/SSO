package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Role;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for {@code GET /role/getRoles} and the
 * create / update endpoints.
 */
public record RoleResponse(
        Long id,
        String name,
        String description
) {
    public static RoleResponse fromEntity(Role r) {
        return new RoleResponse(r.getId(), r.getName(), r.getDescription());
    }

    public static List<RoleResponse> fromEntities(List<Role> roles) {
        return roles.stream().map(RoleResponse::fromEntity).toList();
    }

    /**
     * Returns just the role names, for endpoints that
     * historically returned a {@code List<String>} of role
     * names (e.g. {@code GET /getRolesByUsername}).
     */
    public static List<String> namesFromEntities(List<Role> roles) {
        return roles.stream().map(Role::getName).collect(Collectors.toList());
    }

    /**
     * Same but for a {@code Set} (e.g. from a User's {@code
     * getRoles()}).
     */
    public static Set<String> namesFromRoleSet(Set<Role> roles) {
        return roles.stream().map(Role::getName).collect(Collectors.toCollection(java.util.LinkedHashSet::new));
    }
}
