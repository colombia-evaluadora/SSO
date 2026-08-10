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
}
