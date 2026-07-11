package com.co.eurekatic.ssoadmin.exception;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

/**
 * Translates {@link AccessDeniedException} thrown from the
 * catalog services ({@code QueryCatalogService},
 * {@code WriteCatalogService}) into a 403 response.
 *
 * <p><b>Why this is necessary:</b> the
 * {@code AccessDeniedException} class is the same one Spring
 * Security's {@code ExceptionTranslationFilter} catches —
 * BUT only when it's thrown INSIDE the security filter chain.
 * Our services run inside the controller, after the filter
 * chain has finished, so the framework's default 403 path
 * does not fire. Without this handler the exception bubbles
 * up as a generic 500 Internal Server Error, leaking the
 * authorization decision to the client and to the access
 * log.
 *
 * <p>Why we keep the same exception class: it signals
 * "denied" (vs "not found" or "validation error") without
 * forcing the service to know about HTTP status codes.
 *
 * <p>Scope: scoped to {@code com.co.eurekatic.ssoadmin}
 * (this package) rather than the global controller tree, so
 * it doesn't override the more specific CRUD-level advice
 * (NotFoundException → 404, validation → 422) on the admin
 * endpoints — those don't throw AccessDeniedException anyway.
 */
@RestControllerAdvice(basePackages = "com.co.eurekatic.ssoadmin")
public class CatalogAccessDeniedHandler {

    @ExceptionHandler(AccessDeniedException.class)
    public ResponseEntity<Map<String, Object>> handle(AccessDeniedException ex) {
        // We deliberately do NOT echo the message back to the
        // client — the catalog is not a discovery service
        // and the message names the uuid. A probe that
        // receives the same body for "missing" and "forbidden"
        // can't tell them apart.
        return ResponseEntity.status(HttpStatus.FORBIDDEN).body(Map.of(
                "code", "ACCESS_DENIED",
                "message", "Access denied"));
    }
}