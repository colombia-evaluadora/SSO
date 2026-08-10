package com.co.eurekatic.hello;

import com.co.eurekatic.common.openapi.OpenApiFactory;
import io.swagger.v3.oas.models.OpenAPI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI metadata for hello-service — the reference reactive
 * downstream that demonstrates how X-Authenticated-* headers flow
 * from the api-gateway. The bearer-jwt scheme is added globally so
 * Swagger UI's "Authorize" button is wired up by default; both
 * endpoints on the controller are JWT-protected (the gateway's
 * deny-by-default rule rejects anonymous calls before they reach
 * this service).
 */
@Configuration
public class HelloOpenApiConfig {

    @Bean
    public OpenAPI helloServiceOpenAPI() {
        return OpenApiFactory.baseOpenApi()
                .info(OpenApiFactory.info(
                        "hello-service",
                        "1.0",
                        "Reference reactive downstream. Consumes the X-Authenticated-* "
                                + "headers that api-gateway/UserForwardingGlobalFilter injects. "
                                + "Trusts the gateway as its auth boundary; does not re-validate "
                                + "the JWT (safe because this service is reachable only via the "
                                + "gateway over the locked-down docker network)."))
                .addSecurityItem(OpenApiFactory.bearerJwtRequirement());
    }
}
