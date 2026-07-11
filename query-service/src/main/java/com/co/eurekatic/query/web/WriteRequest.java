package com.co.eurekatic.query.web;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.util.Map;

/**
 * Request body for the write path ({@code /write}).
 *
 * <p>{@code uuid} resolves to a {@code WriteDefinition} in
 * the catalog. The {@code columns} map binds values to the
 * columns declared by that definition — anything not in the
 * declared column list is rejected, and any declared column
 * not present in the map is rejected too.
 *
 * <p>No table name and no column names come from the client
 * — only values. The catalog is the source of truth for
 * shape; the controller refuses to run a write whose
 * declared shape doesn't match the request.
 */
public record WriteRequest(
        @NotBlank String uuid,
        @NotNull Map<String, Object> columns
) {}