package com.co.eurekatic.query.exception;

import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.convert.ConversionFailedException;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.HttpMediaTypeNotAcceptableException;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.HandlerMethodValidationException;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.server.ResponseStatusException;

import java.io.IOException;
import java.lang.reflect.Method;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Centralized exception → HTTP mapping. Maps any client-input
 * failure to the appropriate 4xx so the caller can render a
 * meaningful error; reserves 500 for actual server-side bugs.
 *
 * <p><b>Why every common 4xx has an explicit handler:</b>
 * Spring's default error pages emit a status without a body,
 * which legacy load balancers, curl scripts and the admin-ui's
 * {@code useQuery} error branch can't render. Keeping a uniform
 * {@code {code, message, ...}} envelope across every failure
 * mode is what makes the difference between "el llamante sabe qué
 * arreglar" and "el operador recibe una alarma a las 3am".
 *
 * <p><b>What this advice does NOT do:</b> it doesn't write the
 * raw request body to the response (PII risk) — only the byte
 * offset and a category tag cross the wire; the offending
 * fragment is logged server-side, gated by
 * {@code spring.jackson.parser.include-source-in-location}.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    private final MeterRegistry meters;

    public GlobalExceptionHandler(MeterRegistry meters) {
        this.meters = meters;
    }

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> handleResponseStatus(ResponseStatusException ex) {
        return ResponseEntity.status(ex.getStatusCode()).body(Map.of(
                "code", ex.getStatusCode().toString(),
                "message", ex.getReason() == null ? "Error en la solicitud" : ex.getReason()));
    }

    /**
     * Cuerpo JSON inválido — Jackson no logró leerlo. Se clasifica
     * por causa raíz para que el operador sepa si fue sintaxis
     * rota, un tipo no parseable, una propiedad desconocida o un
     * error de coerción. La causa raíz puede venir de Jackson 2
     * (Boot 4 autoconfig del MVC) o de Jackson 3 (transitivo), así
     * que se cubren ambas familias.
     *
     * <p>El log del servidor incluye el byte offset y, si está
     * habilitado {@code StreamReadFeature.INCLUDE_SOURCE_IN_LOCATION},
     * el fragmento responsable. La respuesta NUNCA devuelve el
     * cuerpo recibido — sólo el offset y la categoría — para no
     * filtrar PII accidentalmente.
     */
    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<Map<String, Object>> handleUnreadable(HttpMessageNotReadableException ex) {
        Throwable cause = deepestCause(ex);
        String category = categorize(cause);
        Location loc = extractLocation(cause);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", "BAD_REQUEST");
        body.put("category", category);
        body.put("message", publicMessage(cause, category));
        if (loc != null) {
            body.put("byteOffset", loc.byteOffset);
            body.put("line", loc.line);
            body.put("column", loc.column);
        }
        log.error("Body parse error category={} offset={}: {}",
                category,
                loc == null ? "?" : loc.byteOffset,
                cause == null ? ex.getMessage() : cause.getMessage());
        meters.counter("query.http.errors", "status", "400", "category", category).increment();
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(body);
    }

    private static Throwable deepestCause(Throwable t) {
        Throwable cur = t;
        // Recorre la cadena buscando el primer nodo cuya clase
        // sea de un paquete de Jackson — los envoltorios de
        // Spring no añaden información útil para clasificar.
        for (Throwable c = cur.getCause(); c != null && c != cur; c = c.getCause()) {
            String cn = c.getClass().getName();
            if (cn.startsWith("com.fasterxml.jackson.")
                    || cn.startsWith("tools.jackson.")) {
                return c;
            }
            cur = c;
        }
        return cur;
    }

    /**
     * Clasifica por nombre de clase para no acoplarse a una
     * versión concreta de Jackson. Boot 4 trae Jackson 2 por
     * autoconfig del MVC y Jackson 3 transitivo; un futuro
     * switch de uno a otro no debe tocar este handler.
     */
    private static String categorize(Throwable cause) {
        if (cause == null) return "OTHER";
        String cn = cause.getClass().getName();
        if (cn.endsWith(".StreamReadException")
                || cn.endsWith(".JsonParseException")
                || cn.endsWith(".JsonEOFException")
                || cn.endsWith(".TokenStreamException")
                || cn.endsWith(".JsonReadException")
                || cn.endsWith(".UnexpectedEndOfInputException")) {
            return "MALFORMED";
        }
        if (cn.endsWith(".InvalidFormatException")
                || cn.endsWith(".MismatchedInputException")
                || cn.endsWith(".InvalidNullException")
                || cn.endsWith(".InvalidTypeIdException")
                || cn.endsWith(".InvalidDefinitionException")
                || cn.endsWith(".UnrecognizedPropertyException")) {
            return "TYPE_MISMATCH";
        }
        if (cause instanceof ConversionFailedException
                || cause instanceof IllegalArgumentException) {
            return "CONVERSION";
        }
        return "OTHER";
    }

    /**
     * Localización agnóstica de versión. Jackson 2 expone
     * {@code JsonLocation.getByteOffset()}; Jackson 3 expone
     * {@code TokenStreamLocation.getByteOffset()}. En vez de
     * importarlos (lo que ata el handler a una versión),
     * buscamos por reflexión cualquier método
     * {@code getLocation()} que devuelva algo con
     * {@code getByteOffset()}.
     */
    private record Location(long byteOffset, long line, long column) {}

    private static Location extractLocation(Throwable cause) {
        if (cause == null) return null;
        for (Throwable c = cause; c != null; c = c.getCause()) {
            Object loc = invokeIfPresent(c, "getLocation");
            if (loc == null) continue;
            Object offObj = invokeIfPresent(loc, "getByteOffset");
            if (!(offObj instanceof Number off)) continue;
            long ln  = asLong(invokeIfPresent(loc, "getLineNr"));
            long col = asLong(invokeIfPresent(loc, "getColumnNr"));
            return new Location(off.longValue(), Math.max(ln, 0L), Math.max(col, 0L));
        }
        return null;
    }

    private static long asLong(Object o) {
        return o instanceof Number n ? n.longValue() : -1L;
    }

    private static Object invokeIfPresent(Object target, String name) {
        if (target == null) return null;
        try {
            Method m = target.getClass().getMethod(name);
            return m.invoke(target);
        } catch (ReflectiveOperationException e) {
            return null;
        }
    }

    /**
     * Lo que se devuelve al cliente. Nunca el cuerpo, nunca la
     * traza. La causa se acorta para que el toast del admin-ui
     * no se descuadre.
     */
    private static String publicMessage(Throwable cause, String category) {
        String base = switch (category) {
            case "MALFORMED" -> "Cuerpo JSON con sintaxis inválida";
            case "TYPE_MISMATCH" -> "Tipo de un campo del cuerpo no es el esperado";
            case "INVALID_DEFINITION" -> "Estructura del cuerpo no coincide con el endpoint";
            case "CONVERSION" -> "No se pudo convertir un valor del cuerpo";
            default -> "Cuerpo JSON inválido";
        };
        if (cause == null) return base;
        String detail = cause.getMessage();
        if (detail == null || detail.isBlank()) return base;
        String trimmed = detail.length() > 240 ? detail.substring(0, 240) + "…" : detail;
        return base + ": " + trimmed;
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
     * V81 — una o más restricciones de formato declaradas en
     * {@code QUERY_PARAM_CONSTRAINT} (ver
     * {@code com.co.eurekatic.common.query.ParamConstraintValidator})
     * fallaron. Mismo envelope {@code {code, message, fields}} que
     * {@link #handleArgumentNotValid} usa para Bean Validation — el
     * admin-ui ya sabe renderizar un error por campo con esa forma.
     */
    @ExceptionHandler(ParamConstraintViolationException.class)
    public ResponseEntity<Map<String, Object>> handleParamConstraintViolation(
            ParamConstraintViolationException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "PARAM_CONSTRAINT_VIOLATION",
                "message", "Uno o más parámetros no cumplen las restricciones de formato",
                "fields", ex.getFieldErrors()));
    }

    /**
     * Content-Type no soportado por el endpoint. 415 con el
     * {@code Accept} correcto para que el cliente pueda
     * corregirse sin tener que mirar la documentación.
     */
    @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
    public ResponseEntity<Map<String, Object>> handleMediaTypeUnsupported(
            HttpMediaTypeNotSupportedException ex) {
        String supported = ex.getSupportedMediaTypes().stream()
                .map(Object::toString)
                .collect(java.util.stream.Collectors.joining(", "));
        log.warn("Unsupported media type {}; supported={}",
                ex.getContentType(),
                supported);
        return ResponseEntity.status(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
                .header("Accept", supported)
                .body(Map.of(
                        "code", "UNSUPPORTED_MEDIA_TYPE",
                        "message", "Content-Type no admitido. Aceptados: " + supported));
    }

    /**
     * Accept no negociable con la respuesta posible. Típico
     * cuando el cliente pide {@code Accept: text/plain} y el
     * endpoint sólo sabe responder JSON.
     */
    @ExceptionHandler(HttpMediaTypeNotAcceptableException.class)
    public ResponseEntity<Map<String, Object>> handleMediaTypeNotAcceptable(
            HttpMediaTypeNotAcceptableException ex) {
        String produced = ex.getSupportedMediaTypes().stream()
                .map(Object::toString)
                .collect(java.util.stream.Collectors.joining(", "));
        return ResponseEntity.status(HttpStatus.NOT_ACCEPTABLE)
                .body(Map.of(
                        "code", "NOT_ACCEPTABLE",
                        "message", "El servidor sólo puede producir: " + produced));
    }

    /**
     * Fallo de validación de Bean Validation sobre el cuerpo
     * ({@code @Valid} en {@code @RequestBody}). Spring lo
     * emite como {@code MethodArgumentNotValidException} y
     * trae los field errors — los volcamos todos en el cuerpo
     * para que el operador vea de un vistazo qué campo(s)
     * fallaron.
     */
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Map<String, Object>> handleArgumentNotValid(
            MethodArgumentNotValidException ex) {
        Map<String, String> fields = new LinkedHashMap<>();
        ex.getBindingResult().getFieldErrors().forEach(fe ->
                fields.put(fe.getField(), fe.getDefaultMessage()));
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "VALIDATION_FAILED",
                "message", "El cuerpo no supera la validación",
                "fields", fields));
    }

    /**
     * Bean Validation sobre parámetros (Boot 4 + Spring 7 lo
     * separan del anterior). Mensaje único por defecto, sin
     * detalle de campos: si se necesita por campo, ver
     * {@link #handleArgumentNotValid}.
     */
    @ExceptionHandler(HandlerMethodValidationException.class)
    public ResponseEntity<Map<String, Object>> handleHandlerMethodValidation(
            HandlerMethodValidationException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "VALIDATION_FAILED",
                "message", ex.getReason() == null
                        ? "Validación de método fallida"
                        : ex.getReason()));
    }

    /**
     * Conversión de tipo fallida en un parámetro de query o de
     * path (p. ej. {@code @RequestParam Long id} y llegan
     * letras). No es 500 — el cliente envió basura.
     */
    @ExceptionHandler(MethodArgumentTypeMismatchException.class)
    public ResponseEntity<Map<String, Object>> handleTypeMismatch(
            MethodArgumentTypeMismatchException ex) {
        String required = ex.getRequiredType() == null
                ? "?"
                : ex.getRequiredType().getSimpleName();
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "BAD_REQUEST",
                "message", "El parámetro '" + ex.getName()
                        + "' no se pudo convertir a " + required));
    }

    @ExceptionHandler(ConversionFailedException.class)
    public ResponseEntity<Map<String, Object>> handleConversionFailed(
            ConversionFailedException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "CONVERSION_FAILED",
                "message", ex.getMessage()));
    }

    /**
     * Multipart demasiado grande. Boot 4 usa 413 por defecto
     * pero el cuerpo queda vacío; lo cerramos con envelope
     * para que el admin-ui pueda mostrar "archivo excede X".
     */
    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<Map<String, Object>> handlePayloadTooLarge(
            MaxUploadSizeExceededException ex) {
        long max = ex.getMaxUploadSize();
        return ResponseEntity.status(HttpStatus.PAYLOAD_TOO_LARGE).body(Map.of(
                "code", "PAYLOAD_TOO_LARGE",
                "message", "El cuerpo excede el límite" + (max > 0 ? " de " + max + " bytes" : "")));
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
        // El cliente se desconectó a mitad de stream — no es un
        // bug, es un cierre abrupto de conexión. Logueamos en
        // DEBUG para no contaminar Grafana con picos de "errores"
        // que en realidad son clientes con red inestable.
        if (isClientDisconnect(ex)) {
            log.debug("Client disconnected mid-request: {}", ex.getMessage());
            return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                    "code", "CLIENT_DISCONNECT",
                    "message", "El cliente cerró la conexión antes de terminar el envío"));
        }
        log.error("Unhandled error", ex);
        meters.counter("query.http.errors", "status", "500", "category", "UNHANDLED").increment();
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                "code", "INTERNAL_ERROR",
                "message", "Error interno del servidor"));
    }

    /**
     * Heurística para distinguir un cierre de conexión del
     * cliente (red inestable, timeout del browser) de un fallo
     * del servidor. La excepción llega envuelta y depende del
     * servlet container, así que se mira por nombre de clase y
     * mensaje.
     */
    private static boolean isClientDisconnect(Throwable t) {
        for (Throwable c = t; c != null; c = c.getCause()) {
            String cn = c.getClass().getName();
            if (cn.endsWith(".ClientAbortException")
                    || cn.endsWith(".EOFException")
                    || cn.endsWith(".EofException")
                    || cn.endsWith(".ConnectionClosedException")
                    || (c instanceof IOException io && io.getMessage() != null
                            && io.getMessage().toLowerCase().contains("connection reset"))) {
                return true;
            }
        }
        return false;
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