package com.co.eurekatic.auth.exception;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.resource.NoResourceFoundException;

import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(EmailAlreadyExistsException.class)
    public ResponseEntity<Map<String, Object>> handleEmailAlreadyExists(EmailAlreadyExistsException ex) {
        return error(HttpStatus.CONFLICT, "DUPLICATE_EMAIL", ex.getMessage(), null);
    }

    @ExceptionHandler(ForbiddenException.class)
    public ResponseEntity<Map<String, Object>> handleForbidden(ForbiddenException ex) {
        return error(HttpStatus.FORBIDDEN, "FORBIDDEN", ex.getMessage(), null);
    }

    @ExceptionHandler(AccessDeniedException.class)
    public ResponseEntity<Map<String, Object>> handleAccessDenied(AccessDeniedException ex) {
        throw ex;
    }

    @ExceptionHandler(AuthenticationException.class)
    public ResponseEntity<Map<String, Object>> handleAuthentication(AuthenticationException ex) {
        throw ex;
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<Map<String, Object>> handleNoResource(NoResourceFoundException ex) {
        throw ex;
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Map<String, Object>> handleValidation(MethodArgumentNotValidException ex) {
        List<Map<String, String>> fieldErrors = new ArrayList<>();
        ex.getBindingResult().getFieldErrors().forEach(fe -> {
            Map<String, String> entry = new LinkedHashMap<>();
            entry.put("field", fe.getField());
            entry.put("message", fe.getDefaultMessage());
            fieldErrors.add(entry);
        });
        Map<String, Object> extras = new LinkedHashMap<>();
        extras.put("fieldErrors", fieldErrors);
        return error(HttpStatus.BAD_REQUEST, "VALIDATION", "Bean Validation falló", extras);
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> handleIllegalArgument(IllegalArgumentException ex) {
        return error(HttpStatus.BAD_REQUEST, "VALIDATION", ex.getMessage(), null);
    }

    /**
     * Translates PostgreSQL integrity violations into the matching
     * HTTP status. The trigger and PL/pgSQL functions raise errors
     * with deterministic SQLSTATE codes; we unpack the wrapped
     * {@link SQLException} via {@code DataIntegrityViolationException}
     * to recover {@code getSQLState()}.
     */
    @ExceptionHandler(DataIntegrityViolationException.class)
    public ResponseEntity<Map<String, Object>> handleDataIntegrity(DataIntegrityViolationException ex) {
        SQLException sql = findSqlException(ex);
        String sqlState = sql != null ? sql.getSQLState() : null;
        String message = sql != null && sql.getMessage() != null ? sql.getMessage() : ex.getMostSpecificCause().getMessage();

        if ("23505".equals(sqlState)) {
            return error(HttpStatus.CONFLICT, "DUPLICATE", message, Map.of("sqlState", sqlState));
        }
        if ("23502".equals(sqlState)) {
            return error(HttpStatus.BAD_REQUEST, "VALIDATION_REQUIRED", message, null);
        }
        if ("23503".equals(sqlState)) {
            return error(HttpStatus.UNPROCESSABLE_ENTITY, "FK_NOT_FOUND", message, null);
        }
        if ("42501".equals(sqlState)) {
            return error(HttpStatus.FORBIDDEN, "FORBIDDEN", message, null);
        }
        if ("22023".equals(sqlState)) {
            return error(HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_VALUE", message, null);
        }
        log.error("Unhandled DataIntegrityViolationException sqlState={}", sqlState, ex);
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "DB_ERROR", message, null);
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleAny(Exception ex) {
        log.error("Unhandled exception in auth-center", ex);
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR",
                "Ocurrió un error inesperado", null);
    }

    private static SQLException findSqlException(Throwable t) {
        Throwable cur = t;
        while (cur != null) {
            if (cur instanceof SQLException sql) {
                return sql;
            }
            if (cur.getCause() == cur) {
                break;
            }
            cur = cur.getCause();
        }
        return null;
    }

    private static ResponseEntity<Map<String, Object>> error(
            HttpStatus status, String code, String message, Map<String, ?> extras) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", code);
        body.put("message", message);
        body.put("timestamp", Instant.now().toString());
        if (extras != null) {
            body.putAll(extras);
        }
        return ResponseEntity.status(status).body(body);
    }
}
