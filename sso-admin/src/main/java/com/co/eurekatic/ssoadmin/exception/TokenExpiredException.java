package com.co.eurekatic.ssoadmin.exception;

/**
 * Thrown when an activation / restore-password token is found
 * but past its expiry timestamp ({@code token_activation_expires_at}
 * / {@code token_restore_expires_at}). Distinct from
 * {@link TokenNotFoundException} so the client can tell "never
 * existed" apart from "existed, ask for a new one" — mapped to
 * HTTP 410 Gone by {@link GlobalExceptionHandler}.
 */
public class TokenExpiredException extends RuntimeException {
    public TokenExpiredException() {
        super("Token has expired");
    }
}
