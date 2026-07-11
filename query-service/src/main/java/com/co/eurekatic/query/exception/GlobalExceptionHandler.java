package com.co.eurekatic.query.exception;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

import java.util.Map;

/**
 * Centralized exception → HTTP mapping. The catalog
 * client already throws {@link ResponseStatusException}
 * with the right status; this advice mostly handles the
 * residual {@link IllegalArgumentException} (a malformed
 * request body) and the catch-all 500.
 *
 * <p><b>Why the explicit ResponseStatusException handler:</b>
 * Spring 7 by default emits a plain status with no body.
 * Some clients (legacy load balancers, curl scripts)
 * expect a JSON envelope so they can render an error
 * message. We keep the response shape uniform across
 * endpoints.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> handleResponseStatus(ResponseStatusException ex) {
        return ResponseEntity.status(ex.getStatusCode()).body(Map.of(
                "code", ex.getStatusCode().toString(),
                "message", ex.getReason() == null ? "error" : ex.getReason()));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> handleIllegal(IllegalArgumentException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "BAD_REQUEST",
                "message", ex.getMessage() == null ? "Bad request" : ex.getMessage()));
    }

    /**
     * Missing required {@code @RequestParam} (e.g.
     * {@code GET /columns?dialect=...&schema=...}
     * with no {@code table=...}). Spring 7 ships an
     * opinionated default for this, but our catch-all
     * {@link #handleAny(Exception)} below catches it first
     * and returns 500 (despite 400 being the only honest
     * answer). The admin-ui's {@code useQuery} error
     * branch treats 400 vs 500 differently — a 500 looks
     * like the server is on fire and hides the actual
     * validation message.
     *
     * <p>Mapping this explicitly to 400 also matches the
     * envelope ({@code code="BAD_REQUEST"}) every other
     * client-input error uses, so the caller can render
     * a uniform "La columna 'foo' es requerida" toast.
     */
    @ExceptionHandler(MissingServletRequestParameterException.class)
    public ResponseEntity<Map<String, Object>> handleMissingParam(MissingServletRequestParameterException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "BAD_REQUEST",
                "message", "falta el parámetro requerido '" + ex.getParameterName() + "'"));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleAny(Exception ex) {
        log.error("Unhandled error", ex);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                "code", "INTERNAL_ERROR",
                "message", "Internal server error"));
    }
}