package com.co.eurekatic.gateway.openapi;

/**
 * Where the aggregator should look up the spec for one service.
 *
 * <p>{@link #SPRINGDOC} (the default) — fetch the service's own
 * springdoc-generated {@code /v3/api-docs} via Eureka + WebClient.
 * Use for services this repo ships (auth-center, sso-admin,
 * query-service, hello-service, provisioner, notification-service).
 *
 * <p>{@link #CATALOG} — poll sso-admin's
 * {@code /internal/openapi/catalog} endpoint and translate each
 * {@code endpoint} row into a minimal OpenAPI stub. Use for
 * partner / external services that don't ship a springdoc spec
 * but are documented in sso-admin's catalog.
 */
public enum Source {
    SPRINGDOC,
    CATALOG
}
