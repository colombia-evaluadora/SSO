package com.co.eurekatic.comms.chat;

import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

import java.util.Map;

/** Error de negocio con status y {@code {message}}, la forma que muestra el front. */
public class ApiError extends RuntimeException {

    private final int status;

    public ApiError(int status, String message) {
        super(message);
        this.status = status;
    }

    @RestControllerAdvice
    static class Advice {
        @ExceptionHandler(ApiError.class)
        ResponseEntity<Map<String, String>> api(ApiError e) {
            return ResponseEntity.status(e.status).body(Map.of("message", e.getMessage()));
        }

        @ExceptionHandler({HttpMessageNotReadableException.class, MethodArgumentTypeMismatchException.class})
        ResponseEntity<Map<String, String>> invalida(Exception e) {
            return ResponseEntity.badRequest().body(Map.of("message", "Solicitud invalida."));
        }
    }
}
