package com.co.eurekatic.common.security;

/**
 * Raised by {@link RefreshTokenStore} implementations when the
 * backing store is unreachable, times out, or returns an unexpected
 * error. The auth-center filter chain and the refresh/logout
 * controllers catch this and fail closed — the bypass-era behaviour
 * of "first enabled user gets a token" must never re-emerge as a
 * fallback.
 *
 * <p>The exception type deliberately lives next to the store
 * interface so any implementation (Redis now, perhaps a JDBC
 * implementation later for offline envs) raises the same type and
 * the same catch-block logic applies.
 */
public class RefreshUnavailableException extends RuntimeException {

    public RefreshUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}