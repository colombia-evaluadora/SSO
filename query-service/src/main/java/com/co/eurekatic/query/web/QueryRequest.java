package com.co.eurekatic.query.web;

import jakarta.validation.constraints.NotBlank;

import java.util.Map;

/**
 * Request body for the read path ({@code /query},
 * {@code /service}, {@code /serviceFit},
 * {@code /public/service}).
 *
 * <p>{@code uuid} is the catalog uuid. {@code params} holds
 * the values for the {@code :placeholder} tokens in the
 * catalog query string. {@code limit} / {@code offset}
 * support the legacy pagination convention used by the
 * serviceFit endpoint.
 *
 * <p>Validation: only {@code uuid} is mandatory.
 */
public record QueryRequest(
        @NotBlank String uuid,
        Map<String, Object> params,
        Integer limit,
        Integer offset
) {
    public QueryRequest {
        if (params == null) params = Map.of();
    }
}