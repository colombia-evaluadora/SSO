package com.co.eurekatic.ssoadmin.exception;

/**
 * El estado actual de la fila en Postgres ya no coincide con lo que el
 * cambio de auditoría esperaba encontrar ANTES de revertir (alguien la
 * volvió a tocar después). Revertir a ciegas pisaría ese cambio
 * intermedio sin que nadie se entere — se rechaza en vez de eso.
 */
public class RevertConflictException extends RuntimeException {
    public RevertConflictException(String message) {
        super(message);
    }
}
