package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.entity.Microservice;

import java.time.LocalDateTime;

/**
 * Response shape for the microservice CRUD endpoints. The
 * legacy returned a richer bag (including a list of bound
 * endpoint ids in some calls); we keep it simple and add the
 * endpoint-list getter on a separate, dedicated endpoint.
 *
 * <p>{@code createdDate} is DB-managed (Postgres
 * {@code TIMESTAMP DEFAULT now()}). It is read-only in JPA
 * ({@code insertable=false, updatable=false}) and serialized
 * as an ISO-8601 string by Jackson.
 *
 * <p>The seven trailing fields mirror
 * {@link MicroserviceRequest}; they are populated only for
 * {@code kind=QUERY} rows (REST rows keep them null).
 */
public record MicroserviceResponse(
        Long id,
        String serviceId,
        String description,
        String requestUri,
        String targetUriPath,
        String targetUrlHost,
        String targetUrlPort,
        LocalDateTime createdDate,

        /* ====================== provisioning (QUERY kind) ====================== */
        String kind,
        String dialect,
        String jdbcUrl,
        String dbUsername,
        /** Never echoed back to clients — {@code fromEntity} passes
         *  {@code null} here so the wire shape omits it. The DB column
         *  is the source of truth for round-trips that need to
         *  re-provision the container. */
        String dbPassword,
        Integer poolSize,
        String instanceName,
        Long appId,
        String appName
) {
    public static MicroserviceResponse fromEntity(Microservice m) {
        App app = m.getApp();
        return new MicroserviceResponse(
                m.getId(),
                m.getServiceId(),
                m.getDescription(),
                m.getRequestUri(),
                m.getTargetUriPath(),
                m.getTargetUrlHost(),
                m.getTargetUrlPort(),
                m.getCreatedDate(),
                m.getKind(),
                m.getDialect(),
                m.getJdbcUrl(),
                m.getDbUsername(),
                /* dbPassword intentionally NOT echoed back to clients. */
                null,
                m.getPoolSize(),
                m.getInstanceName(),
                app != null ? app.getId() : null,
                app != null ? app.getName() : null);
    }
}