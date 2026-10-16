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

    /**
     * DETAIL del RAISE, solo para los códigos que el esquema emite a propósito
     * para el cliente (conflicto offline: JSON con el valor actual). Null en el
     * resto: el DETAIL del motor trae valores reales y nunca se publica.
     */
    private final String detail;

    public DataAccessErrorException(HttpStatus status, String code, String message) {
        this(status, code, message, null);
    }

    public DataAccessErrorException(HttpStatus status, String code, String message, String detail) {
        super(status, message);
        this.code = code;
        this.detail = detail;
    }

    public String code() {
        return code;
    }

    public String detail() {
        return detail;
    }
}
