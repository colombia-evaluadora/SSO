package com.co.eurekatic.provisioner;

import com.co.eurekatic.common.openapi.OpenApiFactory;
import io.swagger.v3.oas.models.OpenAPI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI metadata for the provisioner sidecar. The bearer-jwt
 * scheme is registered for completeness but no global
 * {@code addSecurityItem(...)} is added — the service has no
 * SecurityConfig (it relies on the docker network as its trust
 * boundary), so the rendered Swagger UI's "Authorize" button is
 * informational only.
 */
@Configuration
public class ProvisionerOpenApiConfig {

    @Bean
    public OpenAPI provisionerOpenAPI() {
        return OpenApiFactory.baseOpenApi()
                .info(OpenApiFactory.info(
                        "provisioner",
                        "1.0",
                        "Container lifecycle sidecar — translates sso-admin's "
                        + "kind=QUERY rows into Docker Engine API calls. Sole caller is "
                        + "sso-admin over the internal docker network; not reachable from "
                        + "the public internet."));
    }
}
