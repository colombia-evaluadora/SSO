package com.co.eurekatic.ssoadmin.exception;

/**
 * Thrown when a unique-key conflict is detected for a generic
 * resource (microservice, endpoint, route). Mapped to HTTP
 * 409 Conflict by {@link GlobalExceptionHandler}. The
 * user-specific flavor is {@link UserDuplicateException}; that
 * one stays separate so callers can branch on type if they
 * want to (e.g. distinct logging).
 */
public class DuplicateException extends RuntimeException {
    public DuplicateException(String resource, String key) {
        super(resource + " already exists: " + key);
    }
}
