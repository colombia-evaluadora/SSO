package com.co.eurekatic.notificationservice.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.springframework.boot.jackson2.autoconfigure.Jackson2ObjectMapperBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Jackson customisations. The {@code JavaTimeModule} is
 * required to deserialise {@code metadata.timestamp} as
 * an {@link java.time.Instant} — without it, the listener
 * throws {@code InvalidDefinitionException} at runtime.
 *
 * <p>Spring Boot 4 moved the classic Jackson 2.x builder
 * customizer from {@code org.springframework.boot.autoconfigure.jackson}
 * (Boot 3) to {@code org.springframework.boot.jackson2.autoconfigure}.
 * We register a customizer rather than a replacement
 * {@code @Primary ObjectMapper} so every other
 * Jackson-dependent piece of the stack keeps the same
 * configuration.
 *
 * <p>Note: Spring Boot 4 ships a second, parallel Jackson 3.x
 * stack under {@code tools.jackson.core} (transitively). We
 * intentionally use the classic {@code com.fasterxml.jackson}
 * 2.x APIs — the rest of the project and our external
 * dependencies (Twilio, Firebase Admin) all target 2.x.
 */
@Configuration
public class JacksonConfig {

    @Bean
    Jackson2ObjectMapperBuilderCustomizer jacksonCustomizer() {
        return builder -> builder.modules(new JavaTimeModule());
    }
}