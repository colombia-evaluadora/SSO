package com.co.eurekatic.query.web;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.util.Map;

/**
 * Request body for the write path ({@code /write}).
 *
 * <p>{@code uuid} resolves to a {@code WriteDefinition} in
 * the catalog. The {@code columns} map binds values to the
 * columns declared by that definition: every declared column
 * must be present, and a key the definition does not declare
 * is ignored — the statement is built from the declared list,
 * so an extra key has nowhere to land.
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