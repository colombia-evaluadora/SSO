package com.co.eurekatic.ssoadmin.controller.internal;

import com.co.eurekatic.common.entity.Microservice;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Pins the service-id contract the api-gateway depends on.
 *
 * <p>The gateway builds {@code lb://<serviceId>} straight from
 * this feed, so a bare {@code eval-col} here means every
 * {@code /api/eval-col/**} request 404s at the load balancer —
 * the exact failure this test exists to prevent.
 */
class InternalGatewayControllerTest {

    private static Microservice row(String kind, String serviceId,
                                    String instanceName, String dialect) {
        Microservice m = new Microservice();
        m.setKind(kind);
        m.setServiceId(serviceId);
        m.setInstanceName(instanceName);
        m.setDialect(dialect);
        return m;
    }

    @Test
    void restRowsKeepTheirCatalogServiceId() {
        assertEquals("sso-admin",
                InternalGatewayController.eurekaServiceId(
                        row("REST", "sso-admin", null, null)));
    }

    @Test
    void queryRowsGetTheProvisionerPrefix() {
        assertEquals("query-service-eval-col",
                InternalGatewayController.eurekaServiceId(
                        row("QUERY", "eval-col", "eval-col", "postgres")));
    }

    @Test
    void queryRowsWithoutInstanceNameFallBackToDialect() {
        assertEquals("query-service-postgres",
                InternalGatewayController.eurekaServiceId(
                        row("QUERY", "legacy", null, "postgres")));
    }

    @Test
    void queryRowsAlreadyCarryingThePrefixAreNotDoubled() {
        assertEquals("query-service-eval-col",
                InternalGatewayController.eurekaServiceId(
                        row("QUERY", "eval-col", "query-service-eval-col", null)));
    }

    @Test
    void queryRowsWithNoNameAtAllFallBackToServiceId() {
        assertEquals("eval-col",
                InternalGatewayController.eurekaServiceId(
                        row("QUERY", "eval-col", null, null)));
    }

    @Test
    void stripPrefixCountsSegmentsBeforeTheWildcard() {
        assertEquals(2, InternalGatewayController.stripPrefixFrom("/api/eval-col/**"));
        assertEquals(1, InternalGatewayController.stripPrefixFrom("/sso-admin/**"));
        assertEquals(0, InternalGatewayController.stripPrefixFrom("/**"));
    }

    @Test
    void publicQueryServesOnlyPublicRows() {
        com.co.eurekatic.common.repository.QueryRepository repo =
                org.mockito.Mockito.mock(com.co.eurekatic.common.repository.QueryRepository.class);
        com.co.eurekatic.common.entity.Query pub = new com.co.eurekatic.common.entity.Query();
        pub.setUuid("pub");
        pub.setQuery("SELECT 1");
        pub.setPublicEnd(true);
        com.co.eurekatic.common.entity.Query priv = new com.co.eurekatic.common.entity.Query();
        priv.setUuid("priv");
        priv.setQuery("SELECT 1");
        org.mockito.Mockito.when(repo.findByUuid("pub")).thenReturn(java.util.Optional.of(pub));
        org.mockito.Mockito.when(repo.findByUuid("priv")).thenReturn(java.util.Optional.of(priv));
        org.mockito.Mockito.when(repo.findByUuid("nada")).thenReturn(java.util.Optional.empty());
        InternalGatewayController c = new InternalGatewayController(null, repo);

        assertEquals("pub", c.publicQuery("pub").uuid());
        for (String uuid : java.util.List.of("priv", "nada")) {
            org.springframework.web.server.ResponseStatusException e = org.junit.jupiter.api.Assertions
                    .assertThrows(org.springframework.web.server.ResponseStatusException.class,
                            () -> c.publicQuery(uuid));
            assertEquals(403, e.getStatusCode().value());
        }
    }
}
