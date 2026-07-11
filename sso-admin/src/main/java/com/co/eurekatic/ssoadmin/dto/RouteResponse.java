package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Route;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for the route CRUD endpoints. Includes the
 * bound role ids so the legacy UI can render the multi-select
 * without a follow-up round-trip. {@code idParent} is null
 * for root routes (the legacy "0" sentinel is normalized away
 * on write, never echoed back).
 *
 * <p>No {@code appId}/{@code appName} field: a route's app
 * membership is a {@code app_route} M:N (a route can belong to
 * more than one app), not a single FK — see
 * {@code AppController.getRoutesForAppChecked}/
 * {@code AppService.bindRoute}/{@code unbindRoute} for the
 * membership-management surface.
 */
public record RouteResponse(
        Long id,
        String name,
        String icon,
        String path,
        Integer menuOrder,
        String type,
        Long idParent,
        Set<Long> roleIds
) {
    public static RouteResponse fromEntity(Route r) {
        return new RouteResponse(
                r.getId(),
                r.getName(),
                r.getIcon(),
                r.getPath(),
                r.getMenuOrder(),
                r.getType(),
                r.getIdParent(),
                r.getRoles().stream()
                        .map(com.co.eurekatic.common.entity.Role::getId)
                        .collect(Collectors.toCollection(LinkedHashSet::new)));
    }
}
