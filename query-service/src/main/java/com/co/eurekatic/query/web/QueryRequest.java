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
 * <p><b>Caller identity is NOT a request field.</b> The
 * controller resolves it from the JWT principal (via the
 * SecurityContext that the JwtAuthenticationFilter populates)
 * and {@link com.co.eurekatic.query.read.QueryService} reads
 * it directly from there. Putting it on the wire would let a
 * client forge its own userId/email/roles — exactly what the
 * HS256-signed JWT prevents.
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
