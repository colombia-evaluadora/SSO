package com.co.eurekatic.ssoadmin.dto;

import java.util.List;
import java.util.Map;

/**
 * Response of {@code GET /query/param-types}. Exposes the curated PG/JDBC
 * type set ({@link com.co.eurekatic.common.query.ParamTypes#CURATED})
 * to the admin UI so it doesn't have to hardcode a copy that could drift.
 *
 * <p>{@code jdbcTypes} is the same name-to-{@link java.sql.Types} map
 * the runtime uses, useful if a future UI wants to show the JDBC type
 * alongside the friendly name. Today only {@code curated} is consumed.
 *
 * <p>The set changes rarely, so the UI caches it aggressively
 * ({@code staleTime: Infinity}) and refreshes on deploy.
 */
public record ParamTypesResponse(
        List<String> curated,
        Map<String, Integer> jdbcTypes
) { }