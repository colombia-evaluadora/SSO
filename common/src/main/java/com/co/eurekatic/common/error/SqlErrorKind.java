package com.co.eurekatic.common.error;

/**
 * Clasificación semántica de un error SQL, independiente del framework web.
 *
 * <p>Cada servicio decide el status HTTP que le corresponde según su propio
 * contrato — aquí sólo viaja el significado, el código estable que el cliente
 * puede discriminar y el texto por defecto cuando el mensaje original no se
 * puede reenviar.
 */
public enum SqlErrorKind {

    NOT_FOUND("NOT_FOUND",
            "El registro solicitado no existe o no está activo"),

    PERMISSION_DENIED("FORBIDDEN",
            "No tienes permisos para realizar esta acción"),

    DUPLICATE("DUPLICATE",
            "Ya existe un registro con los datos indicados"),

    MISSING_REQUIRED("VALIDATION_REQUIRED",
            "Falta un campo obligatorio"),

    REFERENCE_MISSING("FK_NOT_FOUND",
            "La referencia indicada no existe o no está activa"),

    INVALID_VALUE("INVALID_VALUE",
            "Un valor enviado no tiene el formato o el rango esperado"),

    BUSINESS_RULE("BUSINESS_RULE",
            "La operación no cumple una regla de negocio"),

    CONFLICT("CONFLICT",
            "La operación entra en conflicto con el estado actual de los datos"),

    UNAVAILABLE("DB_UNAVAILABLE",
            "Servicio de datos no disponible; reintenta en unos segundos"),

    INTERNAL("DB_ERROR",
            "Error interno del servidor");

    private final String code;
    private final String defaultMessage;

    SqlErrorKind(String code, String defaultMessage) {
        this.code = code;
        this.defaultMessage = defaultMessage;
    }

    public String code() {
        return code;
    }

    public String defaultMessage() {
        return defaultMessage;
    }
}
