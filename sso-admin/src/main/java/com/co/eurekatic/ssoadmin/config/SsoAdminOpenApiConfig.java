package com.co.eurekatic.ssoadmin.config;

import com.co.eurekatic.common.openapi.OpenApiFactory;
import io.swagger.v3.oas.models.OpenAPI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI metadata for sso-admin. Like auth-center this service mixes
 * public flows (the email-link activation/restore/forgotPassword family)
 * and protected flows gated by SsoAdminAccessManager; we therefore leave
 * the global {@code addSecurityItem(...)} off and rely on per-operation
 * {@code @SecurityRequirement(name = "bearer-jwt")} annotations to mark
 * the locked endpoints.
 */
@Configuration
public class SsoAdminOpenApiConfig {

    @Bean
    public OpenAPI ssoAdminOpenAPI() {
        return OpenApiFactory.baseOpenApi()
                .info(OpenApiFactory.info(
                        "sso-admin",
                        "1.0",
                        "User/Role/Group/Microservice/Endpoint/Route catalog CRUD, "
                                + "account activation, password restore. Authorization is "
                                + "enforced by SsoAdminAccessManager (role_app + role_endpoint "
                                + "intersection); even ADMIN is not a bypass."));
    }
}
