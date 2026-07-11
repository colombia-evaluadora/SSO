package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Endpoint;

/**
 * Response shape for the endpoint CRUD endpoints. Includes
 * the bound microservice ids so the legacy UI can render
 * the multi-select without a follow-up round-trip.
 */
public record EndpointResponse(
        Long id,
        String method,
        String path,
        String description,
        Integer numberParams,
        java.util.Set<Long> microserviceIds
) {
    public static EndpointResponse fromEntity(Endpoint e) {
        return new EndpointResponse(
                e.getId(),
                e.getMethod(),
                e.getPath(),
                e.getDescription(),
                e.getNumberParams(),
                e.getMicroservices().stream()
                        .map(com.co.eurekatic.common.entity.Microservice::getId)
                        .collect(java.util.stream.Collectors.toCollection(java.util.LinkedHashSet::new)));
    }
}
