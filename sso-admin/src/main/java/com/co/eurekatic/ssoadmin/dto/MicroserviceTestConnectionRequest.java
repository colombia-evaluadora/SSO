package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Sonda sin persistencia para el flujo "crear microservicio QUERY".
 *
 * <p>Slim a propósito: el endpoint {@code POST /microservice/testConnection}
 * solo necesita los campos JDBC. Reusar {@link MicroserviceRequest}
 * arrastraría {@code kind}, {@code serviceId}, validación cross-field y
 * una API menos explícita.
 *
 * <p>El {@code dialect} es opcional: lo usamos para enriquecer el
 * mensaje de respuesta, no para validar (la validación es del driver).
 */
public record MicroserviceTestConnectionRequest(
        @NotBlank @Size(max = 1000) String jdbcUrl,
        @NotBlank @Size(max = 120)  String dbUsername,
        @Size(max = 500)            String dbPassword,
        @Size(max = 40)             String dialect
) {}