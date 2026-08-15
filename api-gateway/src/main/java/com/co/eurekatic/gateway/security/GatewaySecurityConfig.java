package com.co.eurekatic.gateway.security;

import com.co.eurekatic.common.security.CorsProperties;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.SecurityWebFiltersOrder;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.security.web.server.authentication.HttpStatusServerEntryPoint;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.reactive.CorsConfigurationSource;
import org.springframework.web.cors.reactive.CorsWebFilter;
import org.springframework.web.cors.reactive.UrlBasedCorsConfigurationSource;

import java.util.List;

/**
 * Reactive Spring Security 6 configuration for the gateway.
 *
 * <p>Public paths (no auth):
 * <ul>
 *   <li>{@code /actuator/health}, {@code /actuator/health/**}, {@code /actuator/info}</li>
 *   <li>{@code OPTIONS /**} (CORS preflight)</li>
 * </ul>
 *
 * <p>Paths that require authentication with a specific role:
 * <ul>
 *   <li>{@code /getUsersSSO} — requires {@code ADMIN}. Anonymous
 *       callers cannot see user enumeration (the default would
 *       otherwise reach auth-center through the gateway with no
 *       credentials). Uses {@code hasAuthority} not {@code hasRole}
 *       for the same reason as auth-center: {@link
 *       ReactiveJwtAuthenticationFilter} stores role names WITHOUT
 *       the {@code ROLE_} prefix. Defense-in-depth: even though
 *       auth-center re-checks the role after the gateway forwards,
 *       rejecting here keeps the request off the wire.</li>
 * </ul>
 *
 * <p>All other paths require a valid Bearer token, validated by
 * {@link ReactiveJwtAuthenticationFilter}. The filter runs at the
 * {@code AUTHENTICATION} order so its SecurityContext is in place
 * before Spring Security's authorization evaluation runs.
 *
 * <p>CORS is permissive in dev; tighten via the gateway's config in
 * production.
 */
@Configuration
@EnableWebFluxSecurity
@EnableConfigurationProperties(CorsProperties.class)
public class GatewaySecurityConfig {

    private static final Logger log = LoggerFactory.getLogger(GatewaySecurityConfig.class);

    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    public SecurityWebFilterChain securityWebFilterChain(
            ServerHttpSecurity http,
            JwtTokenService jwt,
            JwtProperties jwtProperties) {

        ReactiveJwtAuthenticationFilter jwtFilter =
                new ReactiveJwtAuthenticationFilter(jwt, jwtProperties);

        return http
                .csrf(csrf -> csrf.disable())
                // CORS: the explicit CorsWebFilter bean below is the
                // single source of truth. On Spring Cloud Gateway 5.0.2
                // with Spring Security 6.5, calling .cors() in the
                // security chain on top of the global CorsWebFilter
                // causes a double-check race — the global filter
                // approves (Allow-Origin set), then the chain's
                // internal pre-check rejects with 403 "Invalid CORS
                // request". We disable the chain-level CORS handler
                // here and rely on the explicit bean. The chain still
                // authorizes the request — the CORS gate is the
                // bean-level filter that runs first.
                .formLogin(form -> form.disable())
                .httpBasic(basic -> basic.disable())
                .logout(logout -> logout.disable())
                .exceptionHandling(eh -> eh.authenticationEntryPoint(
                        new HttpStatusServerEntryPoint(HttpStatus.UNAUTHORIZED)))
                .authorizeExchange(a -> a
                        .pathMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        // Bare root "/" is permitted so the root-redirect
                        // gateway route (see application.yml) can 302 the
                        // user to /admin/ instead of the security chain
                        // 401-ing them before the redirect runs.
                        .pathMatchers("/").permitAll()
                        .pathMatchers("/admin", "/admin/**").permitAll()
                        // Auth flow: the user has no Bearer token at this
                        // point, so the gateway must let these through
                        // unauthenticated. auth-center enforces its own
                        // auth on business endpoints.
                        //
                        // /getToken removed in this branch (was an MVP
                        // placeholder whose refreshToken param was
                        // decorative). Without this matcher, an
                        // anonymous /getToken falls through to
                        // anyExchange().authenticated() and gets a 401
                        // at the gateway boundary (defense-in-depth
                        // vs auth-center's servlet-side 401).
                        .pathMatchers("/login", "/getApiToken",
                                "/getInfoUser", "/googleLogin").permitAll()
                        // /getUsersSSO discloses usernames + emails + full
                        // names of every active user. Reject unauthenticated
                        // callers at the gateway boundary BEFORE the
                        // request leaves for auth-center. JWT roles on the
                        // reactive SecurityContext are bare role names
                        // (no ROLE_ prefix), so hasAuthority("ADMIN") is
                        // the correct check.
                        .pathMatchers("/getUsersSSO").hasAuthority("ADMIN")
                        .pathMatchers("/auth/refresh", "/auth/logout").permitAll()
                        // /api/** surface for the admin-ui SPA. The auth
                        // flow paths mirror the legacy ones above (the
                        // gateway routes forward them to the same
                        // auth-center endpoints — see application.yml).
                        // /api/sso-admin/** is intentionally NOT in this
                        // list; those calls carry a Bearer token and
                        // fall through to anyExchange().authenticated() —
                        // EXCEPT the three below, which mirror
                        // sso-admin's own SecurityConfig permitAll list
                        // (activateAccount/restorePassword/forgotPassword
                        // are the email-link flow: the user has no
                        // Bearer token yet, same as /login above). This
                        // matcher was missing entirely, so the /api/**
                        // path the SPA actually calls 401'd at the
                        // gateway before ever reaching sso-admin —
                        // found while testing the token-expiry flow.
                        .pathMatchers("/api/sso-admin/activateAccount",
                                "/api/sso-admin/restorePassword",
                                "/api/sso-admin/forgotPassword",
                                "/api/sso-admin/user/activateAccount",
                                "/api/sso-admin/user/restorePassword",
                                "/api/sso-admin/user/forgotPassword").permitAll()
                        .pathMatchers("/auth/login").permitAll()
                        .pathMatchers("/api/auth/login").permitAll()
                        .pathMatchers("/api/auth/refresh", "/api/auth/logout").permitAll()
                        // /api/files/download/** NO lleva permitAll, a
                        // propósito. Hubo un intento de ponérselo para
                        // que un <img src="/api/files/download/123">
                        // funcionara, partiendo de que el navegador
                        // mandaría "la cookie de sesión". No existe tal
                        // cosa: la única cookie que emite el SSO es
                        // sso_refresh (HttpOnly, SameSite=Strict), que
                        // sirve para renovar en /auth/refresh y no para
                        // autenticar peticiones. La autenticación es
                        // Bearer, y un <img> no puede poner cabeceras.
                        //
                        // Así que un <img src> jamás va a autenticarse
                        // contra este gateway, con permitAll o sin él;
                        // lo único que aportaba era exponer el endpoint.
                        // El front descarga el binario con fetch()
                        // llevando el Authorization, y lo pinta desde
                        // un blob URL. file-service verifica la firma
                        // del JWT por su cuenta (ver DownloadController),
                        // así que hay comprobación en los dos sitios.
                        //
                        // Cae en anyExchange().authenticated(), como
                        // /api/files/** (la subida) y todo lo demás.
                        //
                        // /api/files/view/** SÍ lleva permitAll — es el
                        // caso "<img src>" resuelto de otra forma: el
                        // front pide antes, autenticado, un token de un
                        // solo archivo y vida corta a
                        // POST /api/files/view-token/{id} (ese endpoint
                        // NO es público, cae en anyExchange().authenticated()
                        // igual que download), y lo pasa como
                        // ?token=... en la URL de la imagen. Ese token —
                        // no la ausencia de autenticación — es lo que
                        // file-service valida en /files/view/{id} (ver
                        // ViewTokenService); dejar pasar la petición
                        // aquí sin JWT es correcto porque la
                        // autorización real vive en el token, no en esta
                        // capa. Sin este permitAll, un <img> sin
                        // Authorization se queda en 401 antes de llegar
                        // a file-service a validar el token.
                        .pathMatchers("/api/files/view/**").permitAll()
                        .pathMatchers("/actuator/health", "/actuator/health/**",
                                "/actuator/info", "/actuator/prometheus").permitAll()
                        // OpenAPI aggregator — Swagger UI + merged doc + webjars.
                        // Public because the rendered UI helps devs poke the
                        // gateway without a token; the actual API endpoints
                        // listed in the UI still require Bearer (each one is
                        // individually gated by its target service).
                        //
                        // Path notes (2026-08-07, after the V30 OpenAPI
                        // commit landed):
                        //   - /api/docs/** is honored for the JSON spec
                        //     (springdoc.api-docs.path is set in
                        //     application.yml).
                        //   - /api/docs/** is NOT honored for the UI
                        //     redirect: springdoc-openapi 2.8.6 with
                        //     webflux ignores `springdoc.swagger-ui.path`
                        //     when the same value is shared with the
                        //     api-docs.path. The UI still mounts at the
                        //     default `/swagger-ui` and pulls its static
                        //     assets from `/webjars/...`. So we
                        //     permitAll both the custom path (for the
                        //     spec) AND the default paths (for the UI
                        //     bundle and assets).
                        //   - /api/docs/webjars/** is the operator's
                        //     configured webjars prefix; covered by
                        //     /api/docs/** but listed explicitly for
                        //     clarity in case the prefix is later split
                        //     into its own matcher.
                        .pathMatchers("/api/docs", "/api/docs/**",
                                "/webjars/**", "/swagger-ui", "/swagger-ui/**",
                                "/api/docs/webjars/**").permitAll()
                        .anyExchange().authenticated())
                .addFilterAt(jwtFilter, SecurityWebFiltersOrder.AUTHENTICATION)
                .build();
    }

    @Bean
    public CorsWebFilter corsWebFilter() {
        // The single CORS handler. By NOT exposing a
        // CorsConfigurationSource @Bean we keep the auto-configured
        // global CorsWebFilter out of the chain (Spring's
        // CorsAutoConfiguration only wires one when a source bean
        // exists). The .cors() call in securityWebFilterChain is
        // intentionally absent for the same reason — having both
        // produces the 403 race described above.
        CorsProperties props = bindCorsProperties();
        log.info("CORS allowedOrigins={}", props.allowedOrigins());
        CorsConfiguration cfg = new CorsConfiguration();
        cfg.setAllowedOrigins(props.allowedOrigins());
        cfg.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"));
        cfg.setAllowedHeaders(List.of("Authorization", "Content-Type", "X-Requested-With"));
        cfg.setExposedHeaders(List.of("Authorization", "Set-Cookie"));
        cfg.setAllowCredentials(true);
        cfg.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", cfg);
        return new CorsWebFilter(source);
    }

    /**
     * Re-reads the CORS allowlist from the environment. We can't inject
     * {@link CorsProperties} directly into the bean method because
     * Spring's binding happens at startup, and we want the
     * {@code @ConfigurationProperties} bean (which {@code common} exports)
     * to drive this — we look it up by type from the application context
     * via a small helper. For now, we read the property directly via
     * {@code System.getProperty}/{@code getenv}; see
     * {@code application.yml} for the binding.
     */
    private static CorsProperties bindCorsProperties() {
        String raw = System.getProperty("sso.cors.allowed-origins",
                System.getenv().getOrDefault("SSO_CORS_ALLOWED_ORIGINS", ""));
        if (raw == null || raw.isBlank()) {
            return CorsProperties.defaults();
        }
        return new CorsProperties(
                java.util.Arrays.stream(raw.split(","))
                        .map(String::trim)
                        .filter(s -> !s.isEmpty())
                        .toList());
    }
}
