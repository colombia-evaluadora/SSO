package com.co.eurekatic.query.config;

import org.springframework.boot.jackson.autoconfigure.JsonMapperBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.core.StreamReadFeature;

/**
 * V60 — endurecimiento del parseo JSON para el query-service.
 *
 * <p>Spring Boot 4 trae Jackson 3 ({@code tools.jackson.*}) como
 * stack por defecto en el MVC, pero NO expone vía
 * {@code application.yml} el toggle que importa para diagnosticar
 * cuerpos malformados en producción:
 * {@link StreamReadFeature#INCLUDE_SOURCE_IN_LOCATION}. Sin él, el
 * stacktrace dice "[Source: REDACTED (...disabled); byte offset:
 * #201]" y el operador tiene que adivinar qué había en el offset
 * 201.
 *
 * <p>Este customizer activa la feature. Boot 4 sí mapea
 * {@code spring.jackson.json.read} para {@code JsonReadFeature},
 * pero {@code INCLUDE_SOURCE_IN_LOCATION} vive en
 * {@code StreamReadFeature}, no en {@code JsonReadFeature}, y sin
 * este customizer queda en su default (false).
 *
 * <p>Los límites defensivos ({@code max-string-length},
 * {@code max-number-length}) sí están cubiertos por
 * {@code spring.jackson.parser.*} en el application.yml —
 * mantenemos esa configuración allí para que sea visible sin
 * abrir este archivo.
 */
@Configuration
public class JacksonConfig {

    @Bean
    JsonMapperBuilderCustomizer includeSourceOnParseError() {
        return builder -> builder.enable(StreamReadFeature.INCLUDE_SOURCE_IN_LOCATION);
    }
}
