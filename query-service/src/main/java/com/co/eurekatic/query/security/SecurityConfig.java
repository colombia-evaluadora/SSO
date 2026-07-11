package com.co.eurekatic.query.security;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
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
 * Spring Security 7 configuration for query-service.
 *
 * <p>Every business endpoint requires authentication. The
 * per-row authorization (does this caller have a role bound
 * to the uuid they asked for?) is enforced inside the
 * catalog endpoint and inside the read/write services — we
 * don't try to express it as a URL pattern.
 *
 * <p>Public endpoints:
 * <ul>
 *   <li>{@code OPTIONS /**} — CORS preflight.</li>
 *   <li>{@code /actuator/health} and {@code /actuator/info} — health probes.</li>
 *   <li>{@code /public/service} — special-cased read path
 *       for queries marked {@code PUBLIC_END}. Authorization
 *       is the catalog's publicEnd flag, NOT Spring
 *       Security. We use {@code .permitAll()} here and let
 *       the service throw 403 if the resolved query is not
 *       publicEnd.</li>
 * </ul>
 *
 * <p>The {@link PasswordEncoder} bean is declared here
 * only because the api-gateway expects one (consistent with
 * the other services); query-service itself doesn't store
 * credentials.
 */
@Configuration
@EnableWebSecurity
@EnableConfigurationProperties(JwtProperties.class)
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            JwtTokenService jwt,
            JwtProperties jwtProperties) throws Exception {

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
                        // Health probes + Grafana Alloy scrape endpoint. The scraper
                        // lives on the internal docker network; we don't
                        // require an API key here because every other
                        // route does its own JWT check anyway.
                        .requestMatchers("/actuator/health", "/actuator/health/**",
                                "/actuator/info").permitAll()
                        // Public service: per-query authorization
                        // is the publicEnd flag, not a Spring
                        // Security rule. 403 for non-public uuids
                        // is enforced inside the service.
                        .requestMatchers("/public/service").permitAll()
                        // Everything else requires a valid JWT.
                        .anyRequest().authenticated())
                .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)
                .build();
    }

    /**
     * CORS — open in dev, the gateway enforces the real
     * allow-list in prod.
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

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }

    @Bean
    public JwtTokenService jwtTokenService(JwtProperties props) {
        return new JwtTokenService(props);
    }
}