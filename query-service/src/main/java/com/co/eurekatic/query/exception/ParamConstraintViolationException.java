package com.co.eurekatic.query.exception;

import java.util.Map;

/**
 * V81 — el cuerpo/params de la petición viola una o más restricciones
 * de formato declaradas en {@code QUERY_PARAM_CONSTRAINT} (ver
 * {@code com.co.eurekatic.common.query.ParamConstraintValidator}).
 *
 * <p>A diferencia de {@link IllegalArgumentException} (que
 * {@link GlobalExceptionHandler#handleIllegal} traduce a un único
 * mensaje), esta excepción trae TODAS las violaciones encontradas —
 * una por campo — para que el cliente vea de una sola respuesta 400
 * cada corrección que necesita, en vez de un ciclo de "corrijo uno,
 * choco con el siguiente".
 */
public class ParamConstraintViolationException extends RuntimeException {

    private final Map<String, String> fieldErrors;

    public ParamConstraintViolationException(Map<String, String> fieldErrors) {
        super("Uno o más parámetros no cumplen las restricciones de formato declaradas: "
                + fieldErrors);
        this.fieldErrors = fieldErrors;
    }

    public Map<String, String> getFieldErrors() {
        return fieldErrors;
    }
}
