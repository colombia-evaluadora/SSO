package com.co.eurekatic.query.exception;

import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

import java.sql.SQLException;
import java.util.Map;

/**
 * Centralized exception → HTTP mapping. The catalog
 * client already throws {@link ResponseStatusException}
 * with the right status; this advice mostly handles the
 * residual {@link IllegalArgumentException} (a malformed
 * request body) and the catch-all 500.
 *
 * <p><b>Why the explicit ResponseStatusException handler:</b>
 * Spring 7 by default emits a plain status with no body.
 * Some clients (legacy load balancers, curl scripts)
 * expect a JSON envelope so they can render an error
 * message. We keep the response shape uniform across
 * endpoints.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> handleResponseStatus(ResponseStatusException ex) {
        return ResponseEntity.status(ex.getStatusCode()).body(Map.of(
                "code", ex.getStatusCode().toString(),
                "message", ex.getReason() == null ? "Error en la solicitud" : ex.getReason()));
    }

    /**
     * Entrada inválida del llamante. Cubre también las claves que
     * {@code ParamNamespace} rechaza: nombres que no se pueden
     * escribir como bind en el SQL ({@code ?page-size=1}) y pares
     * que sólo se diferencian por la caja
     * ({@code ?estado=a&ESTADO=b}). Son errores de quien llama, no
     * del servidor, y el mensaje es justo el que le dice qué
     * escribir — por eso importa que salgan con 400 y no los trague
     * la caza-todo de abajo como 500.
     */
    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> handleIllegal(IllegalArgumentException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "BAD_REQUEST",
                "message", ex.getMessage() == null ? "Solicitud inválida" : ex.getMessage()));
    }

    /**
     * Missing required {@code @RequestParam} (e.g.
     * {@code GET /columns?dialect=...&schema=...}
     * with no {@code table=...}). Spring 7 ships an
     * opinionated default for this, but our catch-all
     * {@link #handleAny(Exception)} below catches it first
     * and returns 500 (despite 400 being the only honest
     * answer). The admin-ui's {@code useQuery} error
     * branch treats 400 vs 500 differently — a 500 looks
     * like the server is on fire and hides the actual
     * validation message.
     *
     * <p>Mapping this explicitly to 400 also matches the
     * envelope ({@code code="BAD_REQUEST"}) every other
     * client-input error uses, so the caller can render
     * a uniform "La columna 'foo' es requerida" toast.
     */
    @ExceptionHandler(MissingServletRequestParameterException.class)
    public ResponseEntity<Map<String, Object>> handleMissingParam(MissingServletRequestParameterException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "BAD_REQUEST",
                "message", "falta el parámetro requerido '" + ex.getParameterName() + "'"));
    }

    /**
     * V33 — verbo no soportado en una ruta que sí existe.
     *
     * <p>El dispatcher declara GET, POST y PUT. Un DELETE hace que
     * Spring lance {@code HttpRequestMethodNotSupportedException}
     * antes de llegar al controller, así que el 405 que emite el
     * propio dispatcher para "ruta registrada con otro verbo" no
     * cubre este caso — sin este handler, la caza-todo de abajo lo
     * convertía en un 500 que sugería un fallo del servidor cuando
     * el problema era la petición.
     *
     * <p>Se devuelve {@code Allow}, que es lo que la especificación
     * de HTTP exige en un 405 y lo que permite a un cliente
     * descubrir qué puede usar.
     */
    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<Map<String, Object>> handleMethodNotSupported(
            HttpRequestMethodNotSupportedException ex) {
        String allowed = ex.getSupportedHttpMethods() == null
                ? "GET, POST, PUT"
                : ex.getSupportedHttpMethods().stream()
                        .map(Object::toString)
                        .collect(java.util.stream.Collectors.joining(", "));
        return ResponseEntity.status(HttpStatus.METHOD_NOT_ALLOWED)
                .header("Allow", allowed)
                .body(Map.of(
                        "code", "METHOD_NOT_ALLOWED",
                        "message", "El método " + ex.getMethod()
                                + " no se admite. Disponibles: " + allowed
                                + ". Para borrar, publica un procedimiento y "
                                + "llámalo con CALL."));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleAny(Exception ex) {
        log.error("Unhandled error", ex);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                "code", "INTERNAL_ERROR",
                "message", "Error interno del servidor"));
    }

    /**
     * V32 — Spring's {@link DataAccessException} wrapper
     * around JDBC exceptions bubbles up here when a
     * procedure / statement raises a SQL error that
     * {@link com.co.eurekatic.query.read.QueryService} or
     * {@link com.co.eurekatic.query.write.WriteService}
     * didn't catch (e.g. when a controller calls
     * {@code jdbcTemplate} directly). Translate to the
     * same {@link PostgresErrorMapper} mapping the
     * service path uses, so the wire shape is uniform.
     */
    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<Map<String, Object>> handleDataAccess(DataAccessException ex) {
        SQLException sql = ex.getMostSpecificCause() instanceof SQLException
                ? (SQLException) ex.getMostSpecificCause()
                : null;
        ResponseStatusException mapped = sql != null
                ? PostgresErrorMapper.map(sql)
                : new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR,
                        "Database error");
        return ResponseEntity.status(mapped.getStatusCode()).body(Map.of(
                "code", mapped.getStatusCode().toString(),
                "message", mapped.getReason() == null ? "Database error" : mapped.getReason()));
    }

    /**
     * V32 — same shape for raw {@link SQLException}s that
     * escape a service method (shouldn't happen anymore
     * after QueryService wraps them in PostgresErrorMapper,
     * but the catch-all here keeps the wire uniform if
     * a future code path forgets to translate).
     */
    @ExceptionHandler(SQLException.class)
    public ResponseEntity<Map<String, Object>> handleSql(SQLException ex) {
        ResponseStatusException mapped = PostgresErrorMapper.map(ex);
        return ResponseEntity.status(mapped.getStatusCode()).body(Map.of(
                "code", mapped.getStatusCode().toString(),
                "message", mapped.getReason() == null ? "Database error" : mapped.getReason()));
    }

    /**
     * V33 — Resilience4j rate limit hit. Return 429 with a
     * {@code Retry-After} header so the client backs off
     * for the configured window. The default Resilience4j
     * timeout is 0 (fail fast) so the client should retry
     * at most once per {@code query.resilience.rate-limit.window}.
     */
    @ExceptionHandler(RequestNotPermitted.class)
    public ResponseEntity<Map<String, Object>> handleRateLimit(RequestNotPermitted ex) {
        log.warn("Rate limit exceeded: {}", ex.getMessage());
        return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
                .header(HttpHeaders.RETRY_AFTER, "1")
                .body(Map.of(
                        "code", "RATE_LIMITED",
                        "message", "Rate limit exceeded; retry shortly"));
    }

    /**
     * V33 — Resilience4j bulkhead full. Return 503 with a
     * {@code Retry-After} hint. The bulkhead is per-dialect
     * so a slow query on one dialect doesn't affect others,
     * but a hot dialect can still exhaust its own cap.
     */
    @ExceptionHandler(BulkheadFullException.class)
    public ResponseEntity<Map<String, Object>> handleBulkheadFull(BulkheadFullException ex) {
        log.warn("Bulkhead full: {}", ex.getMessage());
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header(HttpHeaders.RETRY_AFTER, "1")
                .body(Map.of(
                        "code", "BULKHEAD_FULL",
                        "message", "Service busy, retry shortly"));
    }
}