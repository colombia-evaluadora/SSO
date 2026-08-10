package com.co.eurekatic.gateway.openapi;

import java.util.List;

/**
 * Static mapping from a service's Eureka {@code serviceId} to the
 * set of gateway paths it serves. Bound from
 * {@code springdoc.aggregator.services[*]} in application.yml.
 *
 * <p>For {@link Source#SPRINGDOC} services, the {@code gatewayPaths}
 * list is multiplied against the service's own paths when assembling
 * the merged doc — e.g. {@code auth-center} exposes
 * {@code GET /getInfoUser} locally, and {@code gatewayPaths}
 * contains {@code /getInfoUser}, so the merged doc has
 * {@code /getInfoUser} as a top-level path.
 *
 * <p>For {@link Source#CATALOG} services, {@code gatewayPaths}
 * carries a single {@code /**}-suffixed prefix that the rows from
 * sso-admin's catalog are joined onto. {@code tagPrefix} becomes
 * the {@code tags} entry on every generated operation so external
 * services cluster separately in the Swagger UI.
 *
 * @param serviceId       Eureka-registered service id (lowercase)
 * @param source          where to read this service's spec from
 * @param gatewayPaths    list of gateway paths (or single prefix for catalog)
 * @param tagPrefix       tag applied to every operation from this service
 *                        (e.g. {@code "auth-center"}, {@code "external:billing"})
 * @param description     free-text surfaced under the service's tag description
 */
public record ServiceGatewayMapping(
        String serviceId,
        Source source,
        List<String> gatewayPaths,
        String tagPrefix,
        String description
) {
}
