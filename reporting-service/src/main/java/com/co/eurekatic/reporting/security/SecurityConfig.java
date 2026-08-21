package com.co.eurekatic.reporting.security;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import com.co.eurekatic.common.security.PasswordEncoderFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import jakarta.servlet.DispatcherType;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

/**
 * Spring Security del reporting-service. Calcado del de query-service
 * a proposito: mismo filtro, misma clave, mismo mapeo de roles.
 *
 * <p>No hay reglas de autorizacion por reporte aca. La pregunta "¿este
 * usuario puede ver estos datos?" no se contesta en una URL: se
 * contesta abajo, cuando el query-service resuelve la fila
 * {@code …/reporte} contra los {@code role_query} que V67 copio del
 * listado, y despues otra vez dentro de la funcion PL/pgSQL, cuyo gate
 * decide que filas devuelve segun el usuario. Duplicar esa decision
 * aca solo abriria la puerta a que las dos respuestas se separen.
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
                        // El dispatch ERROR tiene que pasar. Cuando el
                        // controlador lanza (404 por clave inexistente, 400
                        // por formato invalido), Spring reenvia a /error y en
                        // ese segundo pase el SecurityContext ya viene vacio:
                        // sin esta regla la cadena responde 403 y TAPA el
                        // codigo y el mensaje reales. Cualquier error del
                        // servicio le llegaba al front como un 403 opaco.
                        .dispatcherTypeMatchers(DispatcherType.ERROR).permitAll()
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        .requestMatchers("/actuator/health", "/actuator/health/**",
                                "/actuator/info").permitAll()
                        // Lo consume el agregador de OpenAPI del gateway sin
                        // token; sin permitAll el servicio se cae del doc
                        // unificado de /api/docs.
                        .requestMatchers("/v3/api-docs", "/v3/api-docs/**").permitAll()
                        .anyRequest().authenticated())
                .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)
                .build();
    }

    /** CORS abierto en dev; en prod la lista real la aplica el gateway. */
    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration cfg = new CorsConfiguration();
        cfg.setAllowedOriginPatterns(List.of("*"));
        cfg.setAllowedMethods(List.of("GET", "POST", "OPTIONS"));
        cfg.setAllowedHeaders(List.of("Authorization", "Content-Type", "X-Requested-With"));
        // Content-Disposition tiene que quedar visible: es de donde el
        // navegador saca el nombre del archivo al descargarlo.
        cfg.setExposedHeaders(List.of("Content-Disposition", "X-Report-Rows"));
        cfg.setAllowCredentials(false);
        cfg.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", cfg);
        return source;
    }

    /** Igual que en query-service: no guarda credenciales, pero el
     *  resto del stack espera el bean. */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return PasswordEncoderFactory.create();
    }

    /**
     * JwtTokenService vive en el modulo common pero NO esta anotado como
     * bean: cada servicio lo declara. Sin esto el contexto no arranca
     * ("required a bean of type JwtTokenService"), porque el
     * component-scan de este paquete no alcanza a com.co.eurekatic.common.
     */
    @Bean
    public JwtTokenService jwtTokenService(JwtProperties props) {
        return new JwtTokenService(props);
    }
}
