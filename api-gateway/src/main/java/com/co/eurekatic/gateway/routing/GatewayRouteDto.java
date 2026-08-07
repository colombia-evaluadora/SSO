package com.co.eurekatic.gateway.routing;

/**
 * V27 — wire shape for the route-table feed consumed by
 * {@link CatalogRoutesRefresher} from sso-admin's
 * {@code /internal/gateway/routes} endpoint.
 *
 * <p>Mirrors the record declared on sso-admin's
 * {@code InternalGatewayController.GatewayRoute}; the JSON
 * keys here are the exact field names.
 *
 * @param id          database row id (for log/debug only)
 * @param serviceId   Eureka service id; the gateway forwards
 *                    to {@code lb://<serviceId>}
 * @param requestUri  URL prefix in the request path
 *                    (e.g. {@code "/api/eval-col/**"})
 * @param kind        {@code "REST"} or {@code "QUERY"} —
 *                    informational; the gateway treats both
 *                    uniformly today but a future pass can
 *                    differentiate (e.g. only expose REST
 *                    routes publicly)
 * @param stripPrefix how many path segments to strip before
 *                    forwarding (Spring Cloud Gateway's
 *                    {@code StripPrefix=N} filter)
 */
public record GatewayRouteDto(
        Long id,
        String serviceId,
        String requestUri,
        String kind,
        int stripPrefix
) {}
