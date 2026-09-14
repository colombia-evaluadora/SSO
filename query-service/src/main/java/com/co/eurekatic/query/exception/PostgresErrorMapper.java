package com.co.eurekatic.query.exception;

import com.co.eurekatic.common.error.SqlErrorKind;
import com.co.eurekatic.common.error.SqlErrorSanitizer;
import com.co.eurekatic.common.query.ParamNamespace;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.dao.InvalidDataAccessApiUsageException;
import org.springframework.http.HttpStatus;

import java.sql.SQLException;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Traduce lo que falla al ejecutar el SQL del catálogo a un
 * {@link DataAccessErrorException} con status, código estable y mensaje
 * publicable.
 *
 * <p>Dos orígenes distintos:
 * <ul>
 *   <li>Un {@link SQLException} del motor. La clasificación y la depuración
 *       del mensaje (quitar nombres de tabla, columna y constraint, descartar
 *       el DETAIL con los valores reales) la hace {@link SqlErrorSanitizer},
 *       compartido con el resto de servicios; aquí sólo se asigna el status.</li>
 *   <li>Un {@link DataAccessException} de Spring <b>sin</b> SQLException
 *       debajo. El caso real es {@link InvalidDataAccessApiUsageException}
 *       {@code "No value supplied for the SQL parameter 'X'"}: el SQL
 *       referencia un placeholder que ni el cliente mandó ni el catálogo
 *       declara con tipo (una fila legada sin {@code paramTypes}). Es un
 *       dato que falta en la petición, no un fallo del servidor, y se
 *       responde 400 nombrando el parámetro.</li>
 * </ul>
 */
public final class PostgresErrorMapper {

    private static final Logger log = LoggerFactory.getLogger(PostgresErrorMapper.class);

    private static final Pattern MISSING_PARAM =
            Pattern.compile("No value supplied for the SQL parameter '([^']+)'");

    private PostgresErrorMapper() {}

    public static DataAccessErrorException map(DataAccessException dae) {
        if (dae.getMostSpecificCause() instanceof SQLException sqlEx) {
            return map(sqlEx);
        }
        if (dae instanceof InvalidDataAccessApiUsageException) {
            Matcher m = MISSING_PARAM.matcher(String.valueOf(dae.getMessage()));
            if (m.find()) {
                return missingParam(m.group(1));
            }
        }
        log.error("Fallo de acceso a datos sin SQLException subyacente", dae);
        return new DataAccessErrorException(HttpStatus.INTERNAL_SERVER_ERROR,
                SqlErrorKind.INTERNAL.code(), SqlErrorKind.INTERNAL.defaultMessage());
    }

    public static DataAccessErrorException map(SQLException ex) {
        SqlErrorSanitizer.Sanitized error = SqlErrorSanitizer.sanitize(ex);
        logRaw(error, ex);
        return new DataAccessErrorException(statusFor(error.kind()), error.code(), error.message());
    }

    /**
     * Un placeholder {@code CONTEXT.*} sin valor no lo puede aportar el
     * cliente: viene del JWT, y falta porque la llamada es anónima o el
     * token es anterior al claim. Cualquier otro namespace es un dato de
     * la petición.
     */
    private static DataAccessErrorException missingParam(String placeholder) {
        String ns = placeholder.contains(".")
                ? placeholder.substring(0, placeholder.indexOf('.')).toUpperCase(Locale.ROOT)
                : "";
        if (ParamNamespace.CONTEXT.equals(ns)) {
            log.info("Placeholder de contexto sin valor: {}", placeholder);
            return new DataAccessErrorException(HttpStatus.UNAUTHORIZED, "SESSION_REQUIRED",
                    "Esta consulta requiere una sesión autenticada con los datos de usuario completos");
        }
        log.info("Placeholder sin valor en la petición: {}", placeholder);
        return new DataAccessErrorException(HttpStatus.BAD_REQUEST,
                SqlErrorKind.MISSING_REQUIRED.code(),
                "Falta el parámetro obligatorio '" + placeholder + "'");
    }

    private static HttpStatus statusFor(SqlErrorKind kind) {
        return switch (kind) {
            case NOT_FOUND -> HttpStatus.NOT_FOUND;
            case PERMISSION_DENIED -> HttpStatus.FORBIDDEN;
            case BUSINESS_RULE, INVALID_VALUE, CHECK_FAILED -> HttpStatus.BAD_REQUEST;
            case DUPLICATE, MISSING_REQUIRED, REFERENCE_MISSING, CONFLICT -> HttpStatus.CONFLICT;
            case TIMEOUT -> HttpStatus.GATEWAY_TIMEOUT;
            case UNAVAILABLE -> HttpStatus.SERVICE_UNAVAILABLE;
            case DEFINITION, INTERNAL -> HttpStatus.INTERNAL_SERVER_ERROR;
        };
    }

    /**
     * El mensaje sin depurar sólo existe en el log del servidor, que es donde el
     * operador necesita el nombre real de la constraint o de la función para
     * diagnosticar.
     */
    private static void logRaw(SqlErrorSanitizer.Sanitized error, SQLException ex) {
        switch (error.kind()) {
            case INTERNAL, DEFINITION ->
                    log.error("SQL error sqlState={}: {}", error.sqlState(), ex.getMessage(), ex);
            case UNAVAILABLE, TIMEOUT ->
                    log.warn("DB sqlState={}: {}", error.sqlState(), ex.getMessage());
            default -> log.info("SQL rechazado sqlState={}: {}", error.sqlState(), ex.getMessage());
        }
    }
}
