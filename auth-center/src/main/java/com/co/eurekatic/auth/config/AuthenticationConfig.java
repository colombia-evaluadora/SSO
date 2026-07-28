package com.co.eurekatic.auth.config;

import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.PasswordEncoderFactory;
import com.co.eurekatic.auth.security.AccountStatusChecker;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.core.userdetails.UserDetailsPasswordService;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.password.PasswordEncoder;

/**
 * Wires the {@code AuthenticationManager}, the password encoder, and the
 * JWT token service. Kept separate from {@link SecurityConfig} so the
 * latter stays focused on HTTP-level concerns (filters, matchers, CORS).
 */
@Configuration
public class AuthenticationConfig {

    /**
     * Argon2id para los hashes nuevos, BCrypt sólo para leer los
     * anteriores a la migración. Ver {@link PasswordEncoderFactory}
     * para los parámetros de coste y el porqué del delegante; el
     * rehash de las filas viejas lo hace
     * {@code PasswordUpgradeService} tras un login correcto.
     */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return PasswordEncoderFactory.create();
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
            PasswordEncoder passwordEncoder,
            UserDetailsPasswordService userDetailsPasswordService) {
        DaoAuthenticationProvider provider = new DaoAuthenticationProvider(userDetailsService);
        provider.setPasswordEncoder(passwordEncoder);
        // Habilita el rehash automático BCrypt -> Argon2id. Sin esta
        // línea el provider verifica los hashes viejos correctamente
        // pero nunca los reescribe, y la migración no avanza nunca.
        // Ver PasswordUpgradeService.
        provider.setUserDetailsPasswordService(userDetailsPasswordService);
        // Sustituye a DefaultPreAuthenticationChecks para dar el
        // motivo real cuando la cuenta está inactiva o sin activar,
        // en vez del "credenciales inválidas" que veía el usuario.
        // Ver AccountStatusChecker.
        provider.setPreAuthenticationChecks(new AccountStatusChecker());
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
