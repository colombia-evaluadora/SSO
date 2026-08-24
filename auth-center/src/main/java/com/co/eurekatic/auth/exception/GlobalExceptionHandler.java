package com.co.eurekatic.auth.exception;

import com.co.eurekatic.common.error.SqlErrorKind;
import com.co.eurekatic.common.error.SqlErrorSanitizer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
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
    public ResponseEntity<Map<String, Object>> handleAccessDenied(AccessDeniedException ex) throws AccessDeniedException {
        throw ex;
    }

    @ExceptionHandler(AuthenticationException.class)
    public ResponseEntity<Map<String, Object>> handleAuthentication(AuthenticationException ex) throws AuthenticationException {
        throw ex;
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<Map<String, Object>> handleNoResource(NoResourceFoundException ex) throws NoResourceFoundException {
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
     * Cualquier fallo que venga de la base. Cubre las violaciones de integridad
     * que Spring envuelve en {@link DataIntegrityViolationException} y también
     * los {@code RAISE EXCEPTION} de las funciones PL/pgSQL (P0001, P0002,
     * 42501), que antes caían en la caza-todo y perdían el mensaje que el autor
     * de la función sí quiso comunicar.
     *
     * <p>El texto que sale lo depura {@link SqlErrorSanitizer}: nunca lleva
     * nombres de tabla ni el DETAIL del motor, que en una {@code
     * unique_violation} contiene el valor real que colisionó.
     */
    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<Map<String, Object>> handleDataAccess(DataAccessException ex) {
        SQLException sql = findSqlException(ex);
        if (sql == null) {
            log.error("DataAccessException sin SQLException subyacente", ex);
            return error(HttpStatus.INTERNAL_SERVER_ERROR, SqlErrorKind.INTERNAL.code(),
                    SqlErrorKind.INTERNAL.defaultMessage(), null);
        }
        return fromSql(sql, ex);
    }

    @ExceptionHandler(SQLException.class)
    public ResponseEntity<Map<String, Object>> handleSql(SQLException ex) {
        return fromSql(ex, ex);
    }

    private ResponseEntity<Map<String, Object>> fromSql(SQLException sql, Throwable original) {
        SqlErrorSanitizer.Sanitized sanitized = SqlErrorSanitizer.sanitize(sql);
        if (sanitized.kind() == SqlErrorKind.INTERNAL) {
            log.error("SQL error sqlState={}: {}", sanitized.sqlState(), sql.getMessage(), original);
        } else {
            log.info("SQL rechazado sqlState={}: {}", sanitized.sqlState(), sql.getMessage());
        }
        return error(statusFor(sanitized.kind()), sanitized.code(), sanitized.message(), null);
    }

    private static HttpStatus statusFor(SqlErrorKind kind) {
        return switch (kind) {
            case NOT_FOUND -> HttpStatus.NOT_FOUND;
            case PERMISSION_DENIED -> HttpStatus.FORBIDDEN;
            case DUPLICATE, CONFLICT -> HttpStatus.CONFLICT;
            case MISSING_REQUIRED, BUSINESS_RULE -> HttpStatus.BAD_REQUEST;
            case REFERENCE_MISSING, INVALID_VALUE -> HttpStatus.UNPROCESSABLE_ENTITY;
            case UNAVAILABLE -> HttpStatus.SERVICE_UNAVAILABLE;
            case INTERNAL -> HttpStatus.INTERNAL_SERVER_ERROR;
        };
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
