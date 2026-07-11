package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /role/createRole} and {@code PUT
 * /role/updateRole}. The update variant includes {@code id};
 * the create variant leaves it null and the server assigns it.
 */
public record RoleRequest(
        Long id,
        @NotBlank @Size(max = 64) String name,
        @Size(max = 255) String description
) {}
