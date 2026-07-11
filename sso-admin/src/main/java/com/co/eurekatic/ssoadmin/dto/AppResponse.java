package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.Route;
import com.co.eurekatic.common.entity.User;

import java.time.LocalDateTime;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for the app CRUD endpoints. Inlines the
 * bound ids (roles / users / routes / microservices) so the
 * admin UI doesn't have to fan out four follow-up calls to
 * render the multi-select tabs on the app form.
 *
 * <p>The shape is intentionally flat — no nested objects —
 * so Jackson serializes it without recursive references
 * (the M:N joins on {@link App} would otherwise trigger
 * JPA's "Mutual recursion during bean serialization" warning
 * and bloat the payload with the full reverse tree).
 *
 * <p>{@code createdDate} is DB-managed
 * ({@code insertable=false, updatable=false}); Jackson
 * serializes it as ISO-8601.
 */
public record AppResponse(
        Long id,
        String name,
        String description,
        String launchUrl,
        LocalDateTime createdDate,
        Set<Long> roleIds,
        Set<Long> userIds,
        Set<Long> routeIds,
        Set<Long> microserviceIds
) {
    public static AppResponse fromEntity(App app) {
        return new AppResponse(
                app.getId(),
                app.getName(),
                app.getDescription(),
                app.getLaunchUrl(),
                app.getCreatedDate(),
                ids(app.getRoles()),
                ids(app.getUsers()),
                ids(app.getRoutes()),
                ids(app.getMicroservices()));
    }

    /**
     * Map a set of entities to their ids, preserving the
     * iteration order of the source set (so a multi-select
     * checkbox list in the UI stays stable across reloads).
     */
    private static Set<Long> ids(Set<?> entities) {
        return entities.stream()
                .map(e -> switch (e) {
                    case Role r -> r.getId();
                    case User u -> u.getId();
                    case Route r -> r.getId();
                    case Microservice m -> m.getId();
                    case null, default -> null;
                })
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toCollection(LinkedHashSet::new));
    }
}