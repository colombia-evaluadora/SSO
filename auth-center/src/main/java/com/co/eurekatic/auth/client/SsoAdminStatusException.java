package com.co.eurekatic.auth.client;

/**
 * 4xx de negocio de sso-admin que el front necesita distinguir (404 cuenta
 * inexistente, 409 estado invalido): auth-center lo devuelve con el MISMO
 * status y el mensaje original (ver {@code GlobalExceptionHandler}).
 */
public class SsoAdminStatusException extends RuntimeException {
    private final int status;

    public SsoAdminStatusException(int status, String message) {
        super(message);
        this.status = status;
    }

    public int status() {
        return status;
    }
}
