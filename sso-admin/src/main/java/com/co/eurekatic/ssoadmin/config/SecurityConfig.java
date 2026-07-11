package com.co.eurekatic.ssoadmin.config;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.ssoadmin.service.AppAccessService;
import com.co.eurekatic.ssoadmin.service.EndpointAccessService;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

/**
 * Spring Security 6 configuration for sso-admin.
 *
 * <p>Authorization model: every business endpoint requires the
 * caller's roles to have BOTH a {@code role_app} binding to this
 * console's app ({@code sso.admin.app-name}) AND a {@code
 * role_endpoint} binding matching the specific request — no
 * bypass, not even for ADMIN (see {@link SsoAdminAccessManager}).
 * The V15 migration seeds ADMIN with every endpoint that existed
 * at seed time, so this is a no-op out of the box, but unbinding a
 * specific endpoint from ADMIN via the Endpoints admin screen now
 * genuinely revokes it — deliberately, so the per-endpoint toggle
 * isn't silently inert for the one role most likely to be testing
 * it. Before this class existed at all, {@code role_app} only
 * controlled what {@code /myMenu} showed in the sidebar, and only
 * {@code ROLE_ADMIN} could reach anything here — non-ADMIN roles
 * were 100% blocked regardless of any binding. Everyone (ADMIN
 * included) gets 403 on missing app access or a missing endpoint
 * binding.
 *
 * <p>Public endpoints:
 * <ul>
 *   <li>{@code OPTIONS /**} — CORS preflight.</li>
 *   <li>{@code /actuator/health} and {@code /actuator/info} — health probes.</li>
 *   <li>{@code /getQuery} and {@code /getWrite} — the consumer-facing
 *       catalog endpoints called by {@code query-service}. Authenticated
 *       callers only (a valid JWT must be present), but NO
 *       {@code ROLE_ADMIN} gate — per-row authorization (the role
 *       intersection against the catalog row) is enforced inside
 *       {@link com.co.eurekatic.ssoadmin.service.QueryCatalogService}
 *       and {@link com.co.eurekatic.ssoadmin.service.WriteCatalogService}.
 *       We use {@code .authenticated()} (not {@code permitAll()}) so an
 *       anonymous request is rejected with 401, not 403 — the 401 is
 *       the correct hint that the caller should send credentials.</li>
 * </ul>
 *
 * <p>{@code /activateAccount}, {@code /restorePassword}, and
 * {@code /forgotPassword} are public on the legacy sso-service
 * (a user clicks the email link and lands here without being
 * logged in). We mirror that by listing them explicitly under
 * {@code permitAll()}.
 *
 * <p>Note on CSRF: Spring Security's CSRF protection is
 * intentionally disabled at the chain level (see below). For
 * the activation/restore flows, the single-use {@code token}
 * delivered in the email is the per-account capability — an
 * attacker must already possess the token (which means they
 * already own the user's email inbox) to trigger the flow.
 * The token also acts as a single-use anti-CSRF token: a
 * cross-site {@code <img>} or form post would need the
 * attacker's own token, which they don't have. We do NOT
 * enable Spring's CSRF filter for these endpoints because the
 * token's capability is sufficient and the legitimate caller
 * arrives via the SPA-hosted form (same-origin).
 */
@Configuration
@EnableWebSecurity
@EnableConfigurationProperties(JwtProperties.class)
public class SecurityConfig {

    @Bean
    public SsoAdminAccessManager ssoAdminAccessManager(
            AppAccessService appAccessService,
            EndpointAccessService endpointAccessService,
            AdminAccessProperties adminAccessProperties) {
        return new SsoAdminAccessManager(appAccessService, endpointAccessService,
                adminAccessProperties.appName());
    }

    @Bean
    public SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            JwtTokenService jwt,
            JwtProperties jwtProperties,
            SsoAdminAccessManager ssoAdminAccessManager) throws Exception {

        JwtAuthenticationFilter jwtFilter = new JwtAuthenticationFilter(jwt, jwtProperties);

        return http
                .csrf(csrf -> csrf.disable())
                .cors(cors -> cors.configurationSource(corsConfigurationSource()))
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .formLogin(form -> form.disable())
                .httpBasic(basic -> basic.disable())
                .logout(logout -> logout.disable())
                .authorizeHttpRequests(a -> a
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        // Public — user clicks the activation link
                        // (or the restore-password link) from their
                        // email and lands here without being logged
                        // in. /restorePassword was missing from this
                        // list, which left the restore flow broken
                        // for end users (any anonymous caller hit
                        // the hasRole("ADMIN") fallback and got 403).
                        // Fixed in this branch — all three flows now
                        // sit on equal footing under permitAll().
                        .requestMatchers("/activateAccount", "/restorePassword",
                                "/forgotPassword").permitAll()
                        // Health probes + Grafana Alloy scrape endpoint. Same trust
                        // boundary argument: the scraper lives on the
                        // internal docker network, not on the LAN.
                        .requestMatchers("/actuator/health", "/actuator/health/**",
                                "/actuator/info").permitAll()
                        // Catalog read endpoints — any
                        // authenticated caller; the per-row
                        // role check happens inside the
                        // service. Anonymous → 401, authorized
                        // → 200, wrong-role → 403.
                        //
                        // /myQueries is the list endpoint consumed
                        // by the admin-ui Queries Catalog page; it
                        // is also per-row authorized (ADMIN
                        // bypass + publicEnd bypass + role
                        // intersection), same as /getQuery.
                        .requestMatchers("/getQuery", "/getWrite", "/myQueries", "/myMenu").authenticated()
                        // Everything else requires a role_app binding
                        // to this app AND a matching role_endpoint
                        // binding — see SsoAdminAccessManager. No
                        // bypass for ADMIN on either check. Was bare
                        // hasRole("ADMIN"); that let any ADMIN-named
                        // role into every endpoint here regardless
                        // of whether it was ever scoped to this app,
                        // and blocked every other role outright.
                        .anyRequest().access(ssoAdminAccessManager))
                .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)
                .build();
    }

    /**
     * CORS allowlist. Permissive in dev so curl + browsers work;
     * in production the gateway enforces CORS and this stays
     * open as a defense-in-depth fallback.
     */
    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration cfg = new CorsConfiguration();
        cfg.setAllowedOriginPatterns(List.of("*"));
        cfg.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"));
        cfg.setAllowedHeaders(List.of("Authorization", "Content-Type", "X-Requested-With"));
        cfg.setExposedHeaders(List.of("Authorization"));
        cfg.setAllowCredentials(false);
        cfg.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", cfg);
        return source;
    }

    /**
     * BCrypt with cost 12. Matches the strength used in
     * auth-center so a user created in either module can
     * authenticate against either.
     */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }

    /**
     * JWT parser. sso-admin only verifies tokens — auth-center
     * mints them. The key is the same on both sides
     * ({@code sso.jwt.secret}).
     */
    @Bean
    public JwtTokenService jwtTokenService(JwtProperties props) {
        return new JwtTokenService(props);
    }
}
