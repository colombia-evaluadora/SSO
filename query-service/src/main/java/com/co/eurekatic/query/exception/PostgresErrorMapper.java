package com.co.eurekatic.query.exception;

import com.co.eurekatic.common.error.SqlErrorKind;
import com.co.eurekatic.common.error.SqlErrorSanitizer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.sql.SQLException;

/**
 * Traduce un {@link SQLException} al {@link ResponseStatusException} que
 * corresponde. La depuración del mensaje —quitar nombres de tabla, columna y
 * constraint, y descartar el DETAIL con los valores reales— la hace
 * {@link SqlErrorSanitizer}, compartido con el resto de servicios.
 *
 * <p>Los status se mantienen tal como los publicaba V32 (23xxx → 409,
 * 22xxx → 400, P0001 → 400, P0002 → 404, 42501 → 403): lo que cambia es el
 * texto, no el contrato que ya consume el admin-ui.
 */
public final class PostgresErrorMapper {

    private static final Logger log = LoggerFactory.getLogger(PostgresErrorMapper.class);

    private PostgresErrorMapper() {}

    public static ResponseStatusException map(SQLException ex) {
        SqlErrorSanitizer.Sanitized error = SqlErrorSanitizer.sanitize(ex);
        logRaw(error, ex);
        return new ResponseStatusException(statusFor(error.kind()), error.message());
    }

    private static HttpStatus statusFor(SqlErrorKind kind) {
        return switch (kind) {
            case NOT_FOUND -> HttpStatus.NOT_FOUND;
            case PERMISSION_DENIED -> HttpStatus.FORBIDDEN;
            case BUSINESS_RULE, INVALID_VALUE -> HttpStatus.BAD_REQUEST;
            case DUPLICATE, MISSING_REQUIRED, REFERENCE_MISSING, CONFLICT -> HttpStatus.CONFLICT;
            case UNAVAILABLE -> HttpStatus.SERVICE_UNAVAILABLE;
            case INTERNAL -> HttpStatus.INTERNAL_SERVER_ERROR;
        };
    }

    /**
     * El mensaje sin depurar sólo existe en el log del servidor, que es donde el
     * operador necesita el nombre real de la constraint para diagnosticar.
     */
    private static void logRaw(SqlErrorSanitizer.Sanitized error, SQLException ex) {
        switch (error.kind()) {
            case INTERNAL -> log.error("SQL error sqlState={}: {}", error.sqlState(), ex.getMessage(), ex);
            case UNAVAILABLE -> log.warn("DB no disponible sqlState={}: {}", error.sqlState(), ex.getMessage());
            default -> log.info("SQL rechazado sqlState={}: {}", error.sqlState(), ex.getMessage());
        }
    }
}
