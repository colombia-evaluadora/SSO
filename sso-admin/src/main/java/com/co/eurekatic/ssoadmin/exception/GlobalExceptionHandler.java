package com.co.eurekatic.ssoadmin.exception;

import com.co.eurekatic.ssoadmin.provisioner.ProvisioningException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Maps sso-admin's domain exceptions to HTTP responses with a
 * consistent JSON shape. The shape is intentionally simple —
 * one error code, one human-readable message, a timestamp.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(UserDuplicateException.class)
    public ResponseEntity<Map<String, Object>> handleUserDuplicate(UserDuplicateException ex) {
        return error(HttpStatus.CONFLICT, "USER_DUPLICATE", ex.getMessage());
    }

    @ExceptionHandler(DuplicateException.class)
    public ResponseEntity<Map<String, Object>> handleDuplicate(DuplicateException ex) {
        return error(HttpStatus.CONFLICT, "DUPLICATE", ex.getMessage());
    }

    @ExceptionHandler(EmailInvalidException.class)
    public ResponseEntity<Map<String, Object>> handleEmailInvalid(EmailInvalidException ex) {
        return error(HttpStatus.UNPROCESSABLE_ENTITY, "EMAIL_INVALID", ex.getMessage());
    }

    @ExceptionHandler(TokenNotFoundException.class)
    public ResponseEntity<Map<String, Object>> handleTokenNotFound(TokenNotFoundException ex) {
        return error(HttpStatus.NOT_FOUND, "TOKEN_NOT_FOUND", ex.getMessage());
    }

    @ExceptionHandler(TokenExpiredException.class)
    public ResponseEntity<Map<String, Object>> handleTokenExpired(TokenExpiredException ex) {
        return error(HttpStatus.GONE, "TOKEN_EXPIRED", ex.getMessage());
    }

    @ExceptionHandler(InvalidUserStateException.class)
    public ResponseEntity<Map<String, Object>> handleInvalidUserState(InvalidUserStateException ex) {
        return error(HttpStatus.CONFLICT, "INVALID_USER_STATE", ex.getMessage());
    }

    @ExceptionHandler(NotFoundException.class)
    public ResponseEntity<Map<String, Object>> handleNotFound(NotFoundException ex) {
        return error(HttpStatus.NOT_FOUND, "NOT_FOUND", ex.getMessage());
    }

    /**
     * Catalog endpoints ({@code /getQuery}, {@code /myQueries})
     * throw {@link AccessDeniedException} when the per-row role
     * check rejects a caller. The Spring Security filter chain
     * maps these to 403 already when the chain is present, but
     * the standalone MockMvc setup (and any future programmatic
     * caller that bypasses the filter) needs an explicit handler
     * so the response shape stays consistent with the rest of
     * the API.
     */
    @ExceptionHandler(AccessDeniedException.class)
    public ResponseEntity<Map<String, Object>> handleAccessDenied(AccessDeniedException ex) {
        return error(HttpStatus.FORBIDDEN, "FORBIDDEN", ex.getMessage());
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Map<String, Object>> handleValidation(MethodArgumentNotValidException ex) {
        String details = ex.getBindingResult().getFieldErrors().stream()
                .map(fe -> fe.getField() + ": " + fe.getDefaultMessage())
                .collect(Collectors.joining("; "));
        return error(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", details);
    }

    /**
     * Translates {@link ProvisioningException} into the
     * matching HTTP status. The {@link ProvisioningException.Code}
     * carries enough context to map correctly:
     *
     * <ul>
     *   <li>{@code SIDECAR_UNREACHABLE} → 503 (transient — the
     *       operator should retry once the sidecar comes back).</li>
     *   <li>{@code EUREKA_TIMEOUT} → 504 (the container is up but
     *       didn't register in time — gateway can't route yet).</li>
     *   <li>{@code CONTAINER_CREATE_FAILED} → 502 (the sidecar
     *       or Docker rejected the create — usually a config issue).</li>
     *   <li>{@code INVALID_SPEC} → 400 (caller-side — missing
     *       JDBC URL, bad dialect, etc.).</li>
     * </ul>
     */
    @ExceptionHandler(ProvisioningException.class)
    public ResponseEntity<Map<String, Object>> handleProvisioning(ProvisioningException ex) {
        // Always log: ProvisioningException is rare and never
        // comes from a user mistake alone — it's the supply
        // chain (container engine, sidecar, Eureka) failing.
        // A silent 504/503 in the logs makes post-mortems
        // guesswork, so we surface every occurrence at WARN
        // (ERROR would be reserved for the catch-all below).
        log.warn("ProvisioningException code={} message={}",
                ex.getCode(), ex.getMessage());
        HttpStatus status = switch (ex.getCode()) {
            case SIDECAR_UNREACHABLE -> HttpStatus.SERVICE_UNAVAILABLE;
            case EUREKA_TIMEOUT      -> HttpStatus.GATEWAY_TIMEOUT;
            case CONTAINER_CREATE_FAILED -> HttpStatus.BAD_GATEWAY;
            case INVALID_SPEC        -> HttpStatus.BAD_REQUEST;
        };
        return error(status, ex.getCode().name(), ex.getMessage());
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> handleIllegalArg(IllegalArgumentException ex) {
        // Used for cross-field validation errors raised from
        // MicroserviceService when kind=QUERY but a required
        // JDBC field is missing — Bean Validation can't model
        // that "if-then" rule on records cleanly.
        return error(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", ex.getMessage());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleAny(Exception ex) {
        log.error("Unhandled exception in sso-admin", ex);
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR",
                "An unexpected error occurred");
    }

    private static ResponseEntity<Map<String, Object>> error(
            HttpStatus status, String code, String message) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", code);
        body.put("message", message);
        body.put("timestamp", Instant.now().toString());
        return ResponseEntity.status(status).body(body);
    }
}
