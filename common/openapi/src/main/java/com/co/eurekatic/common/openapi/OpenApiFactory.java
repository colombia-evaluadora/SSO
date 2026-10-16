package com.co.eurekatic.common.openapi;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Contact;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.info.License;
import io.swagger.v3.oas.models.security.SecurityRequirement;
import io.swagger.v3.oas.models.security.SecurityScheme;

/**
 * Builders for {@link OpenAPI} beans shared across every service in
 * the platform. Each service's own {@code OpenApiConfig} composes a
 * service-specific title / version around the common security scheme
 * returned by {@link #bearerJwtSecurityScheme()}.
 *
 * <p>Why static helpers instead of a shared {@code @Configuration}:
 * common is a library module (no Spring context); if we declared a
 * {@code @Configuration} here it would never be component-scanned by
 * downstream services. Static factories sidestep that — each service
 * calls these in its own {@code @Bean} method.
 */
public final class OpenApiFactory {

    /** Canonical name of the bearer-JWT security scheme. Referenced by
     *  every {@code @SecurityRequirement(name = "bearer-jwt")} on
     *  protected operations. */
    public static final String BEARER_JWT_SCHEME_NAME = "bearer-jwt";

    private OpenApiFactory() {}

    /**
     * Builds a fresh {@link OpenAPI} object pre-populated with the
     * {@code bearer-jwt} security scheme. Callers chain
     * {@code .info(...)} and {@code .addSecurityItem(...)} to layer
     * service-specific metadata on top.
     */
    public static OpenAPI baseOpenApi() {
        return new OpenAPI()
                .components(new Components()
                        .addSecuritySchemes(BEARER_JWT_SCHEME_NAME,
                                bearerJwtSecurityScheme()));
    }

    /**
     * Convenience: builds an {@link Info} block with the standard
     * platform contact + Apache-2.0 license. Title and version are
     * per-service.
     */
    public static Info info(String title, String version, String description) {
        return new Info()
                .title(title)
                .version(version)
                .description(description)
                .contact(new Contact().name("EurekaTIC Platform"))
                .license(new License().name("Apache-2.0")
                        .url("https://www.apache.org/licenses/LICENSE-2.0"));
    }

    /**
     * Convenience: a {@link SecurityRequirement} that applies
     * {@code bearer-jwt} globally. Attach it to the {@link OpenAPI}
     * (not individual operations) when you want Swagger UI's
     * "Authorize" button unlocked for the whole document; services
     * that mix public + protected endpoints should leave it off the
     * document and add it per-operation via {@code @SecurityRequirement}.
     */
    public static SecurityRequirement bearerJwtRequirement() {
        return new SecurityRequirement().addList(BEARER_JWT_SCHEME_NAME);
    }

    /**
     * The shared HTTP bearer + JWT scheme. {@code bearerFormat=JWT} is
     * advisory (Swagger UI does not actually parse the token); it
     * makes the rendered docs accurate.
     */
    public static SecurityScheme bearerJwtSecurityScheme() {
        return new SecurityScheme()
                .type(SecurityScheme.Type.HTTP)
                .scheme("bearer")
                .bearerFormat("JWT")
                .description("Paste a JWT issued by auth-center's /login or /getApiToken.");
    }
}
