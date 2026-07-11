package com.co.eurekatic.auth.config;

import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.common.security.JwtProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

/**
 * Wires the {@code AuthenticationManager}, the password encoder, and the
 * JWT token service. Kept separate from {@link SecurityConfig} so the
 * latter stays focused on HTTP-level concerns (filters, matchers, CORS).
 */
@Configuration
public class AuthenticationConfig {

    /**
     * BCrypt with cost 12. The 2024+ OWASP recommendation is 12 or higher
     * for interactive authentication. The legacy code used the default
     * (10) — we bump it for the modernized version.
     */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }

    /**
     * Spring Security 7 migration:
     * <ul>
     *   <li>The no-arg ctor {@code new DaoAuthenticationProvider()} was
     *       removed in Security 7; the {@code setUserDetailsService(...)}
     *       setter was removed at the same time.</li>
     *   <li>The new contract is: the {@link UserDetailsService} is supplied
     *       via the constructor; {@link PasswordEncoder} is supplied via
     *       {@link DaoAuthenticationProvider#setPasswordEncoder} (still
     *       available in 7.0.6 — see javap).</li>
     * </ul>
     * The rest of the wiring is unchanged.
     */
    @Bean
    public DaoAuthenticationProvider daoAuthenticationProvider(
            UserDetailsService userDetailsService,
            PasswordEncoder passwordEncoder) {
        DaoAuthenticationProvider provider = new DaoAuthenticationProvider(userDetailsService);
        provider.setPasswordEncoder(passwordEncoder);
        return provider;
    }

    @Bean
    public AuthenticationManager authenticationManager(
            DaoAuthenticationProvider daoAuthenticationProvider) {
        return new org.springframework.security.authentication.ProviderManager(daoAuthenticationProvider);
    }

    @Bean
    public JwtTokenService jwtTokenService(JwtProperties props) {
        return new JwtTokenService(props);
    }
}
