package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /group} and {@code PUT
 * /group/update}. The update variant includes {@code id}; the
 * create variant leaves it null. {@code POST /group} stays
 * idempotent on {@code name} for create (re-saving a group
 * with the same name returns the existing one) — {@code id} is
 * what routing an update to the right row depends on.
 */
public record GroupRequest(
        Long id,
        @NotBlank @Size(max = 120) String name,
        @Size(max = 255) String description
) {}
