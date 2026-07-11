package com.co.eurekatic.auth.config;

import com.co.eurekatic.auth.security.EffectiveRolesResolver;
import com.co.eurekatic.auth.security.JsonAuthHandlers;
import com.co.eurekatic.auth.security.JsonLoginFilter;
import com.co.eurekatic.auth.security.JwtAuthenticationFilter;
import com.co.eurekatic.common.security.CorsProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.common.security.RefreshTokenStore;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

/**
 * Spring Security 6 configuration. The {@link SecurityFilterChain} bean
 * replaces the legacy {@code WebSecurityConfigurerAdapter}.
 *
 * <p>Public endpoints (no auth required):
 * <ul>
 *   <li>{@code POST /login}</li>
 *   <li>{@code GET /getApiToken}, {@code GET /getInfoUser}</li>
 *   <li>{@code POST /googleLogin} (stub returning 501)</li>
 *   <li>{@code /actuator/health} and {@code /actuator/info}</li>
 *   <li>{@code OPTIONS /**} (CORS preflight)</li>
 * </ul>
 *
 * <p><b>Note:</b> {@code GET /getToken?refreshToken=…} used to live
 * in the permit-all list; it was an MVP placeholder whose
 * {@code refreshToken} parameter was decorative (no store
 * validation). It was removed because the surface was misleading
 * and represented a future-bypass footgun. Clients use
 * {@code POST /auth/refresh} (the cookie-based, store-backed
 * counterpart) instead.
 *
 * <p>Endpoints that require authentication with a specific role:
 * <ul>
 *   <li>{@code GET /getUsersSSO} — requires {@code ADMIN} (closes the
 *       anonymous user-enumeration bug fixed in this branch).
 *       Uses {@code hasAuthority} not {@code hasRole} because
 *       {@link com.co.eurekatic.auth.security.JwtAuthenticationFilter}
 *       stores role names WITHOUT the {@code ROLE_} prefix (the JWT
 *       carries the bare role name). {@code hasRole} would auto-prefix
 *       and therefore mismatch.</li>
 * </ul>
 *
 * <p>Everything else requires a valid Bearer token. CORS is permissive
 * for the MVP because the gateway is the trust boundary; in production
 * this should be tightened to a specific allowlist.
 */
@Configuration
@EnableWebSecurity
@EnableConfigurationProperties(CorsProperties.class)
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            AuthenticationManager authenticationManager,
            JwtTokenService jwt,
            ObjectMapper objectMapper,
            com.co.eurekatic.common.security.JwtProperties jwtProperties,
            CorsProperties corsProperties,
            JsonAuthHandlers handlers,
            RefreshTokenStore refreshTokenStore,
            EffectiveRolesResolver effectiveRolesResolver) throws Exception {

        JsonLoginFilter loginFilter = new JsonLoginFilter(
                authenticationManager, jwt, objectMapper, jwtProperties, refreshTokenStore,
                effectiveRolesResolver);
        JwtAuthenticationFilter jwtFilter = new JwtAuthenticationFilter(jwt, jwtProperties);

        return http
                .csrf(csrf -> csrf.disable())
                .cors(cors -> cors.configurationSource(corsConfigurationSource(corsProperties)))
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .formLogin(form -> form.disable())
                .httpBasic(basic -> basic.disable())
                .logout(logout -> logout.disable())
                .exceptionHandling(eh -> eh
                        .authenticationEntryPoint(handlers.unauthorizedHandler())
                        .accessDeniedHandler(handlers.forbiddenHandler()))
                .authorizeHttpRequests(a -> a
                        .requestMatchers(org.springframework.http.HttpMethod.OPTIONS, "/**").permitAll()
                        // /auth/refresh and /auth/logout are part of the cookie
                        // auth flow. The refresh endpoint requires the cookie
                        // but does NOT require a Bearer token in the header;
                        // the cookie IS the credential. Logout is the same.
                        .requestMatchers("/auth/refresh", "/auth/logout").permitAll()
                        .requestMatchers("/login").permitAll()
                        // /getToken dropped in this branch - see the
                        // class-level Note above. Without this matcher,
                        // anonymous /getToken falls through to
                        // anyRequest().authenticated() and the gateway
                        // gets a clean 401 (no controller to reach).
                        // Authenticated /getToken reaches a Spring MVC
                        // 404 because AuthController no longer handles
                        // the path.
                        .requestMatchers("/getApiToken",
                                "/getInfoUser", "/googleLogin").permitAll()
                        // /getUsersSSO discloses usernames + emails + full
                        // names of every active user. Anonymous callers must
                        // NOT see it. JWT roles land on the SecurityContext
                        // with the bare role name (no ROLE_ prefix), so
                        // hasAuthority("ADMIN") is the correct check.
                        .requestMatchers("/getUsersSSO").hasAuthority("ADMIN")
                        // /actuator/prometheus is read by the Grafana Alloy
                        // scraper over the internal docker network. Same
                        // rationale as /actuator/health: scrapers are
                        // inside the trust boundary, not the public internet.
                        .requestMatchers("/actuator/health", "/actuator/health/**",
                                "/actuator/info").permitAll()
                        // /internal/cache/* is called by sso-admin after a
                        // role / group binding mutation to invalidate the
                        // auth-center's cached role set. The endpoint is
                        // not behind JWT auth — it gates itself with a
                        // shared-secret header (X-Session-Cache-Secret),
                        // because sso-admin's JWT only proves the
                        // caller's identity, not that the caller has a
                        // legitimate reason to drop another user's
                        // cache entry. The docker network is the trust
                        // boundary that keeps the endpoint off the
                        // public internet.
                        .requestMatchers("/internal/cache/**").permitAll()
                        .anyRequest().authenticated())
                .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)
                .addFilterAt(loginFilter, UsernamePasswordAuthenticationFilter.class)
                .build();
    }

    /**
     * CORS allowlist driven by {@link CorsProperties}. We use
     * {@code setAllowedOrigins} (not {@code setAllowedOriginPatterns}) so
     * the wildcard {@code "*"} is rejected at the CORS layer when
     * {@code setAllowCredentials(true)} — exactly the spec behavior we
     * want. Dev defaults are in {@link CorsProperties#defaults()};
     * production sets a real allowlist via env var.
     */
    @Bean
    public CorsConfigurationSource corsConfigurationSource(CorsProperties props) {
        CorsConfiguration cfg = new CorsConfiguration();
        cfg.setAllowedOrigins(props.allowedOrigins());
        cfg.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"));
        cfg.setAllowedHeaders(List.of("Authorization", "Content-Type", "X-Requested-With"));
        cfg.setExposedHeaders(List.of("Authorization", "Set-Cookie"));
        cfg.setAllowCredentials(true);
        cfg.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", cfg);
        return source;
    }
}
