package com.co.eurekatic.files;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;

/**
 * Traduce multipart a JSON: sube cada binario, lo registra en TARCHIVO
 * y sustituye el campo por su id, conservando el nombre del campo.
 *
 * <p>No sabe nada de negocio. Dónde va cada id lo decide el PL/pgSQL
 * del catálogo, así que una operación nueva no toca este servicio.
 */
@SpringBootApplication
@EnableConfigurationProperties(JwtProperties.class)
public class FileServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(FileServiceApplication.class, args);
    }

    /**
     * Verificador de JWT. Sólo con la clave pública: este servicio
     * comprueba firmas, no emite tokens.
     *
     * <p>Lo usa {@link DownloadController} para distinguir a un
     * usuario real de cualquiera que sepa inventarse una cabecera
     * {@code Authorization}. El resto del servicio sigue confiando en
     * que el gateway autenticó antes de reenviar.
     */
    @Bean
    public JwtTokenService jwtTokenService(JwtProperties props) {
        return new JwtTokenService(props);
    }
}
