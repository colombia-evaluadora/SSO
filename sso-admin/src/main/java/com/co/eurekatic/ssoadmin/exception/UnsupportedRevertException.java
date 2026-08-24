package com.co.eurekatic.ssoadmin.exception;

/**
 * Fase 1 del revert de auditoría: solo se soporta deshacer un cambio de
 * la bandera {@code active} (el patrón soft-delete/soft-restore). Un
 * cambio que no calza con ese patrón (otras columnas, operación
 * INSERT/DELETE real, tabla sin bandera active) se rechaza con esto en
 * vez de intentar algo genérico que no se ha validado todavía.
 */
public class UnsupportedRevertException extends RuntimeException {
    public UnsupportedRevertException(String message) {
        super(message);
    }
}
