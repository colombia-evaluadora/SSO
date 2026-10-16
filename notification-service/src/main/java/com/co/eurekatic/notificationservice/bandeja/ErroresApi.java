package com.co.eurekatic.notificationservice.bandeja;

import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

/**
 * Forma de error que espera el front ({@code cleanErrorMessage(data.message)}).
 * Acotado a los controladores de la bandeja, preferencias y push.
 */
@RestControllerAdvice(basePackages = {
        "com.co.eurekatic.notificationservice.bandeja",
        "com.co.eurekatic.notificationservice.preferencias",
        "com.co.eurekatic.notificationservice.push"})
public class ErroresApi {

    @ExceptionHandler(ApiException.class)
    ResponseEntity<Map<String, String>> api(ApiException e) {
        return ResponseEntity.status(e.status()).body(Map.of("message", e.getMessage()));
    }

    @ExceptionHandler({HttpMessageNotReadableException.class, MethodArgumentNotValidException.class,
            IllegalArgumentException.class})
    ResponseEntity<Map<String, String>> invalida(Exception e) {
        return ResponseEntity.badRequest().body(Map.of("message", "Solicitud invalida."));
    }
}
