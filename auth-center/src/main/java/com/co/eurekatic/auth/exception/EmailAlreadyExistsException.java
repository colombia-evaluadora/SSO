package com.co.eurekatic.auth.exception;

public class EmailAlreadyExistsException extends RuntimeException {
    public EmailAlreadyExistsException(String email) {
        super("El correo " + email + " ya está en uso por otra cuenta de acceso.");
    }
}
