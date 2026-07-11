package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.entity.User.UserStatus;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for {@code GET /getUsers} and the create /
 * update endpoints. Never exposes the password hash. The
 * {@code username} slot was removed in the V12 migration —
 * email IS the unique login identifier.
 */
public record UserResponse(
        Long id,
        String fullName,
        String email,
        boolean active,
        boolean ldap,
        UserStatus status,
        Set<String> roleNames
) {
    public static UserResponse fromEntity(User u) {
        Set<String> roles = u.getRoles().stream()
                .map(r -> r.getName())
                .collect(Collectors.toCollection(java.util.LinkedHashSet::new));
        return new UserResponse(
                u.getId(),
                u.getFullName(),
                u.getEmail(),
                u.isActive(),
                u.isLdap(),
                u.getStatus(),
                roles);
    }

    public static List<UserResponse> fromEntities(List<User> users) {
        return users.stream().map(UserResponse::fromEntity).toList();
    }
}
