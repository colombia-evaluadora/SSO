package com.co.eurekatic.notificationservice.bandeja;

/** Error de negocio que la API devuelve como {@code { "message": ... }} con el status dado. */
public class ApiException extends RuntimeException {

    private final int status;

    public ApiException(int status, String message) {
        super(message);
        this.status = status;
    }

    public int status() {
        return status;
    }
}
