package com.co.eurekatic.reporting;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;

/**
 * Servicio de reportes.
 *
 * <p>Su unica responsabilidad es convertir filas en un archivo. NO
 * consulta la base: le pide las filas al query-service reenviando el
 * JWT del llamante, asi que el reporte hereda el gate de autorizacion
 * de cada listado — un rector exporta sus funcionarios, no los de todo
 * el pais — sin reimplementar ni una regla de acceso.
 *
 * <p>Las filas salen de los endpoints {@code …/reporte} registrados en
 * {@code public.query} (V67), que llaman a las mismas funciones
 * PL/pgSQL de las pantallas con las paginas en NULL (V66): mismos
 * filtros, sin tope de filas.
 */
@SpringBootApplication
@EnableDiscoveryClient
@EnableConfigurationProperties(ReportingProperties.class)
public class ReportingServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(ReportingServiceApplication.class, args);
    }
}
