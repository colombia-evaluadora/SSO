package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /endpoint/save} and
 * {@code PUT /endpoint/update}. The legacy uniqueness rule is
 * (PATH, METHOD, DESCRIPTION) — enforced at the DB level and
 * pre-checked in the service layer for a friendlier 409.
 */
public record EndpointRequest(
        Long id,
        @NotBlank @Size(max = 10)  String method,
        @NotBlank @Size(max = 500) String path,
        @Size(max = 500)           String description,
        @Min(0)                    Integer numberParams
) {}
