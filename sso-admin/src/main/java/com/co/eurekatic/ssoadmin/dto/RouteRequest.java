package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /route/save} and
 * {@code PUT /route/update}. The {@code idParent} field
 * accepts the legacy "0" sentinel as "root" — the service
 * layer normalizes that to {@code null} before persisting.
 */
public record RouteRequest(
        Long id,
        @NotBlank @Size(max = 200) String name,
        @Size(max = 200) String icon,
        @NotBlank @Size(max = 500) String path,
        @Min(0)          Integer menuOrder,
        @Size(max = 50)  String type,
        Long idParent
) {}
