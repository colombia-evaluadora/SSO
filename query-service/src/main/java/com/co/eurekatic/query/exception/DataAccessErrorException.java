package com.co.eurekatic.query.exception;

import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

/**
 * Error de acceso a datos ya traducido y depurado, listo para publicarse.
 *
 * <p>Además del status y el mensaje de {@link ResponseStatusException},
 * lleva el {@code code} estable ({@code FK_NOT_FOUND}, {@code
 * QUERY_DEFINITION}, ...) con el que el cliente puede discriminar el caso
 * sin parsear el texto.
 */
public class DataAccessErrorException extends ResponseStatusException {

    private final String code;

    public DataAccessErrorException(HttpStatus status, String code, String message) {
        super(status, message);
        this.code = code;
    }

    public String code() {
        return code;
    }
}
