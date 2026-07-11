package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;

import java.time.LocalDateTime;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for the query CRUD endpoints. Includes the
 * bound role ids so the admin UI can render the multi-select
 * without a follow-up round-trip — same pattern as
 * {@link EndpointResponse}.
 *
 * <p>{@code createdDate} is the DB-managed timestamp
 * (insertable=false, updatable=false on the entity). We surface
 * it for the admin UI; {@code query-service} ignores it.
 *
 * <p>{@code microserviceId} identifies the {@code query-service-<instance>}
 * that owns this query. Surfaced for the admin CRUD form so
 * operators can re-bind a query to a different instance without
 * writing SQL. The admin form does not yet expose this field
 * directly (server-managed for MVP) but the DTO carries it so
 * a follow-up form change is a small edit.
 */
public record QueryResponse(
        Long id,
        String uuid,
        String query,
        String type,
        boolean publicEnd,
        boolean captcha,
        String detail,
        String action,
        String style,
        LocalDateTime createdDate,
        Set<Long> roleIds,
        Long microserviceId
) {
    public static QueryResponse fromEntity(Query q) {
        Microservice m = q.getMicroservice();
        return new QueryResponse(
                q.getId(),
                q.getUuid(),
                q.getQuery(),
                q.getType(),
                q.isPublicEnd(),
                q.isCaptcha(),
                q.getDetail(),
                q.getAction(),
                q.getStyle(),
                q.getCreatedDate(),
                q.getRoles().stream()
                        .map(com.co.eurekatic.common.entity.Role::getId)
                        .collect(Collectors.toCollection(LinkedHashSet::new)),
                m != null ? m.getId() : null);
    }
}
