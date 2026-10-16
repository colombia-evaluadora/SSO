package com.co.eurekatic.notificationservice.security;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

/**
 * Verificacion del JWT para las rutas de usuario. A diferencia de
 * ai-control-service no se usa {@code @EnableConfigurationProperties(JwtProperties)}:
 * su {@code @NotBlank publicKey} impediria arrancar el consumidor de colas en
 * despliegues que aun no pasan {@code JWT_PUBLIC_KEY}. Sin clave, solo las rutas
 * de la bandeja responden 503; el envio por colas sigue funcionando.
 */
@Configuration
public class SeguridadConfig {

    private static final Logger log = LoggerFactory.getLogger(SeguridadConfig.class);

    @Bean
    FilterRegistrationBean<JwtUsuarioFilter> jwtUsuarioFilter(
            @Value("${notif.jwt.public-key:}") String publicKey,
            @Value("${notif.jwt.secret:}") String secret,
            @Value("${notif.jwt.issuer:sso-postgres}") String issuer) {
        JwtTokenService jwt = null;
        if (!publicKey.isBlank() || !secret.isBlank()) {
            jwt = new JwtTokenService(new JwtProperties(null, publicKey.isBlank() ? "-" : publicKey, issuer,
                    0, 0, JwtProperties.DEFAULT_HEADER, JwtProperties.DEFAULT_PREFIX,
                    secret.isBlank() ? null : secret));
        } else {
            log.warn("JWT_PUBLIC_KEY ausente: /notificaciones/** respondera 503 hasta configurarla");
        }
        FilterRegistrationBean<JwtUsuarioFilter> reg = new FilterRegistrationBean<>(new JwtUsuarioFilter(jwt));
        reg.addUrlPatterns("/notificaciones", "/notificaciones/*");
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE + 10);
        return reg;
    }
}
