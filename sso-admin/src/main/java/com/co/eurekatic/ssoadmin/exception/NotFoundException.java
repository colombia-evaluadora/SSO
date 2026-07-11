package com.co.eurekatic.ssoadmin.exception;

/**
 * Generic 404 — resource not found (user, role, group, etc.).
 */
public class NotFoundException extends RuntimeException {
    public NotFoundException(String resource, Object id) {
        super(resource + " not found: " + id);
    }
}
