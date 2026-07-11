package com.co.eurekatic.ssoadmin.exception;

/**
 * Thrown when {@code createAccount} receives an email that
 * doesn't match a basic validity check. Mapped to HTTP 422
 * Unprocessable Entity by {@link GlobalExceptionHandler}.
 */
public class EmailInvalidException extends RuntimeException {
    public EmailInvalidException(String email) {
        super("Invalid email address: " + email);
    }
}
