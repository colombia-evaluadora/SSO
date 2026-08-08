package com.co.eurekatic.files;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Traduce multipart a JSON: sube cada binario, lo registra en TARCHIVO
 * y sustituye el campo por su id, conservando el nombre del campo.
 *
 * <p>No sabe nada de negocio. Dónde va cada id lo decide el PL/pgSQL
 * del catálogo, así que una operación nueva no toca este servicio.
 */
@SpringBootApplication
public class FileServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(FileServiceApplication.class, args);
    }
}
