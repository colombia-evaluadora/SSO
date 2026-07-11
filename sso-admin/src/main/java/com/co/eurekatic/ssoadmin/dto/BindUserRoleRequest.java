package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotNull;

/**
 * Request body for {@code POST /bindUserRole}. Binds a role to
 * a user. Idempotent — re-binding the same pair is a no-op.
 */
public record BindUserRoleRequest(
        @NotNull Long userId,
        @NotNull Long roleId
) {}
