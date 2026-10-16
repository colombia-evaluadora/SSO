package com.co.eurekatic.comms.security;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

@Configuration
public class SeguridadConfig {

    /** Clave publica en produccion; {@code secret} solo en pruebas (HS256). */
    @Bean
    JwtFilter jwtFilter(@Value("${comms.jwt.public-key:}") String publicKey,
                        @Value("${comms.jwt.secret:}") String secret) {
        if (publicKey.isBlank() && secret.isBlank()) {
            throw new IllegalStateException("Falta JWT_PUBLIC_KEY: comms-service no puede verificar tokens");
        }
        return new JwtFilter(new JwtTokenService(new JwtProperties(null, publicKey.isBlank() ? "-" : publicKey,
                "sso-postgres", 0, 0, JwtProperties.DEFAULT_HEADER, JwtProperties.DEFAULT_PREFIX,
                secret.isBlank() ? null : secret)));
    }

    @Bean
    FilterRegistrationBean<JwtFilter> jwtFilterRegistration(JwtFilter filter) {
        FilterRegistrationBean<JwtFilter> reg = new FilterRegistrationBean<>(filter);
        reg.addUrlPatterns("/comms/ws-ticket", "/comunicaciones/*");
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE + 10);
        return reg;
    }
}
