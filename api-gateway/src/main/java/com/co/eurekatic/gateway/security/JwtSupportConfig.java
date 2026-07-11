package com.co.eurekatic.gateway.security;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The {@code common} module's {@link JwtTokenService} is a plain class,
 * not a Spring bean — the gateway has to instantiate it explicitly. We
 * also expose a {@link JwtTokenService} bean so the reactive security
 * filter and any future filters can inject it.
 */
@Configuration
public class JwtSupportConfig {

    @Bean
    public JwtTokenService jwtTokenService(JwtProperties props) {
        return new JwtTokenService(props);
    }
}
