package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.server.ResponseStatusException;

import java.util.Map;

@RestControllerAdvice
public class ManejadorErrores {

    private static final Logger log = LoggerFactory.getLogger(ManejadorErrores.class);

    /**
     * Fichero por encima del límite. 413 y no 500: es un problema de la
     * petición, y el mensaje tiene que decir cuál es el límite o el
     * cliente no puede corregirlo.
     */
    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<Map<String, Object>> demasiadoGrande(MaxUploadSizeExceededException e) {
        return ResponseEntity.status(HttpStatus.PAYLOAD_TOO_LARGE).body(Map.of(
                "code", "PAYLOAD_TOO_LARGE",
                "message", "El fichero supera el tamaño máximo permitido."));
    }

    /**
     * Fallo al subir o al registrar. 502 y no 500: el fallo es del
     * almacén de objetos, no de este servicio, y esa distinción importa
     * cuando alguien mira los logs a las tres de la mañana.
     */
    @ExceptionHandler(TransformadorMultipart.SubidaFallidaException.class)
    public ResponseEntity<Map<String, Object>> subidaFallida(
            TransformadorMultipart.SubidaFallidaException e) {
        log.error("Subida fallida", e);
        return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of(
                "code", "UPLOAD_FAILED",
                "message", "No se pudo almacenar el fichero. No se creó nada a medias."));
    }

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> estado(ResponseStatusException e) {
        return ResponseEntity.status(e.getStatusCode()).body(Map.of(
                "code", e.getStatusCode().toString(),
                "message", e.getReason() == null ? "Error en la solicitud" : e.getReason()));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> resto(Exception e) {
        log.error("Error no controlado", e);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                "code", "INTERNAL_ERROR",
                "message", "Error interno del servidor"));
    }
}
