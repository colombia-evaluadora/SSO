package com.co.eurekatic.query.config;

import com.co.eurekatic.common.openapi.OpenApiFactory;
import io.swagger.v3.oas.models.OpenAPI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI metadata for query-service. The service exposes a
 * heterogeneous surface — anonymous {@code /public/service}, JWT-gated
 * {@code /query} / {@code /write} / {@code /tables} / {@code /columns},
 * header-gated {@code /internal/**} — so the global
 * {@code addSecurityItem(...)} is intentionally omitted and each
 * controller marks its own {@code @SecurityRequirement} per
 * operation via the class-level annotation.
 */
@Configuration
public class QueryOpenApiConfig {

    @Bean
    public OpenAPI queryServiceOpenAPI() {
        return OpenApiFactory.baseOpenApi()
                .info(OpenApiFactory.info(
                        "query-service",
                        "1.0",
                        "Query + write gateway. Resolves a uuid to a SQL definition "
                                + "by calling sso-admin's /getQuery and /getWrite catalog "
                                + "endpoints, then runs the SQL against the appropriate "
                                + "datasource (Postgres / Oracle / SQL Server). Re-validates "
                                + "the JWT locally so it can be exposed behind any ingress."));
    }
}
