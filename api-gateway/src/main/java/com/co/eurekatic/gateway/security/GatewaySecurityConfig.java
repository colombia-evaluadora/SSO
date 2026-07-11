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
                                "/api/sso-admin/forgotPassword").permitAll()
                        .pathMatchers("/auth/login").permitAll()
                        .pathMatchers("/api/auth/login").permitAll()
                        .pathMatchers("/api/auth/refresh", "/api/auth/logout").permitAll()
                        .pathMatchers("/actuator/health", "/actuator/health/**",
                                "/actuator/info", "/actuator/prometheus").permitAll()
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
