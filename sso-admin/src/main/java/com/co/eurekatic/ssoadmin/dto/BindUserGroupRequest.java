package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotNull;

/**
 * Request body for {@code POST /group/bindUserGroup}. Binds a
 * user to a group. Idempotent.
 */
public record BindUserGroupRequest(
        @NotNull Long userId,
        @NotNull Long groupId
) {}
