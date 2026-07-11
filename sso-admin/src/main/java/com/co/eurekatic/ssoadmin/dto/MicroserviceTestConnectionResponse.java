package com.co.eurekatic.ssoadmin.dto;

/**
 * Respuesta de {@code POST /microservice/testConnection}.
 *
 * <p>El campo {@code message} es seguro para mostrar en la UI: nunca
 * contiene la URL completa (que podría llevar credenciales embebidas)
 * ni el password. En éxito es genérico; en fallo es la primera línea
 * del mensaje del driver JDBC (sanitizada por {@code MicroserviceService}).
 */
public record MicroserviceTestConnectionResponse(
        boolean ok,
        String  message,
        long    latencyMs,
        String  dialect
) {
    public static MicroserviceTestConnectionResponse success(String dialect, long ms) {
        return new MicroserviceTestConnectionResponse(true, "Conexión exitosa", ms, dialect);
    }
}