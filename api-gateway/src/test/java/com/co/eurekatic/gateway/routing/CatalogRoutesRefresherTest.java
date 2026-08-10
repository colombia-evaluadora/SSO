package com.co.eurekatic.gateway.routing;

import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.route.RouteDefinition;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CatalogRoutesRefresherTest {

    private static GatewayRouteDto dto(String serviceId, String requestUri,
                                       String kind, int stripPrefix) {
        return new GatewayRouteDto(1L, serviceId, requestUri, kind, stripPrefix);
    }

    @Test
    void queryRowBecomesALoadBalancedRouteWithStripPrefix() {
        RouteDefinition def = CatalogRoutesRefresher.toRouteDefinition(
                dto("query-service-eval-col", "/api/eval-col/**", "QUERY", 2));

        assertEquals("catalog-query-service-eval-col", def.getId());
        assertEquals("lb://query-service-eval-col", def.getUri().toString());
        assertEquals(1, def.getPredicates().size());
        assertEquals("Path", def.getPredicates().get(0).getName());
        assertTrue(def.getPredicates().get(0).getArgs().containsValue("/api/eval-col/**"));
        assertEquals(1, def.getFilters().size());
        assertEquals("StripPrefix", def.getFilters().get(0).getName());
    }

    @Test
    void zeroStripPrefixProducesNoFilter() {
        RouteDefinition def = CatalogRoutesRefresher.toRouteDefinition(
                dto("svc", "/**", "QUERY", 0));

        assertTrue(def.getFilters().isEmpty());
    }

    /**
     * The REST rows in the feed (sso-admin, auth-center) are
     * already routed by application.yml with per-path
     * StripPrefix values. Generating a catch-all
     * Path=/api/auth/** here would shadow the /api/auth/refresh
     * route (StripPrefix=1) with the login shape
     * (StripPrefix=2) and break refresh/logout.
     */
    @Test
    void restRowsAreSkipped() {
        List<RouteDefinition> defs = CatalogRoutesRefresher.toRouteDefinitions(List.of(
                dto("sso-admin", "/api/sso-admin/**", "REST", 2),
                dto("auth-center", "/api/auth/**", "REST", 2),
                dto("query-service-eval-col", "/api/eval-col/**", "QUERY", 2)));

        assertEquals(1, defs.size());
        assertEquals("catalog-query-service-eval-col", defs.get(0).getId());
    }

    @Test
    void kindMatchIsCaseInsensitive() {
        assertEquals(1, CatalogRoutesRefresher.toRouteDefinitions(List.of(
                dto("svc", "/api/x/**", "query", 2))).size());
    }
}
