package com.co.eurekatic.auth.config;

import com.co.eurekatic.common.openapi.OpenApiFactory;
import io.swagger.v3.oas.models.OpenAPI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI metadata for auth-center. The {@code bearer-jwt} security
 * scheme is shared across every service via
 * {@link OpenApiFactory#baseOpenApi()}; the title / version /
 * description are auth-center-specific so the api-gateway aggregator
 * can identify this spec's origin when merging.
 *
 * <p>We deliberately do NOT call {@code .addSecurityItem(...)} here:
 * auth-center exposes a mix of {@code permitAll} flows ({@code /login},
 * {@code /getApiToken}, {@code /auth/refresh}) and JWT-protected flows
 * ({@code /getInfoUser}, {@code /myApps}, {@code /getUsersSSO}).
 * Swagger UI's "Authorize" button is therefore wired per-operation via
 * {@code @SecurityRequirement} on the protected controller methods,
 * keeping the public ones un-locked in the rendered UI.
 */
@Configuration
public class AuthCenterOpenApiConfig {

    @Bean
    public OpenAPI authCenterOpenAPI() {
        return OpenApiFactory.baseOpenApi()
                .info(OpenApiFactory.info(
                        "auth-center",
                        "1.0",
                        "Authentication issuer — login, token issuance, user lookup, "
                                + "cookie-based refresh/logout. Called by the api-gateway and "
                                + "directly by service-to-service callers with an apiToken."));
    }
}
