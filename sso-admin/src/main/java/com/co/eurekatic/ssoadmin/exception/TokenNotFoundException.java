package com.co.eurekatic.ssoadmin.exception;

/**
 * Thrown when an activation / restore-password token is
 * unknown (i.e. not present in the {@code token_activation} or
 * {@code token_restore} column of any user). Mapped to HTTP 404
 * Not Found by {@link GlobalExceptionHandler}.
 */
public class TokenNotFoundException extends RuntimeException {
    public TokenNotFoundException() {
        super("Token not found or already used");
    }
}
