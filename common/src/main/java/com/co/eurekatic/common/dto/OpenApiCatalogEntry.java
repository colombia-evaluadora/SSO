package com.co.eurekatic.common.dto;

import java.util.List;

/**
 * Row of the {@code endpoint} catalog exposed by sso-admin's internal
 * endpoint {@code GET /internal/openapi/catalog}. Consumed by the
 * api-gateway's {@code OpenApiAggregatorService} to assemble the merged
 * OpenAPI document for {@code source=catalog} services (i.e. external
 * microservices that don't ship a springdoc-generated spec).
 *
 * <p>Each entry maps 1:1 to a row in the {@code endpoint} table joined
 * with its owning {@code microservice}. The {@code serviceId} field is
 * the lowercased Eureka service-id (or the value the admin typed in
 * {@code Microservice.serviceId}), so the gateway can correlate this
 * with its static {@code springdoc.aggregator.services} mapping.
 *
 * @param serviceId    owning microservice's service-id (Eureka-registered name)
 * @param path         HTTP path as the admin typed it (e.g. {@code /charge})
 * @param method       HTTP verb, uppercased ({@code GET}/{@code POST}/…)
 * @param description  free-text description stored in {@code endpoint.description}
 * @param roles        role_endpoint bindings currently attached (informational)
 * @param active       mirror of {@code endpoint.active}; false rows are omitted by default
 */
public record OpenApiCatalogEntry(
        String serviceId,
        String path,
        String method,
        String description,
        List<String> roles,
        boolean active
) {
}
