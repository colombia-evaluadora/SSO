package com.co.eurekatic.files;

import com.co.eurekatic.common.error.SqlErrorKind;
import com.co.eurekatic.common.error.SqlErrorSanitizer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClientException;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartException;
import org.springframework.web.multipart.support.MissingServletRequestPartException;
import org.springframework.web.server.ResponseStatusException;

import java.sql.SQLException;
import java.util.Map;

@RestControllerAdvice
public class ManejadorErrores {

    private static final Logger log = LoggerFactory.getLogger(ManejadorErrores.class);

    /**
     * Fichero por encima del límite. 413 y no 500: es un problema de la
     * petición, y el mensaje tiene que decir cuál es el límite o el
     * cliente no puede corregirlo.
     */
    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<Map<String, Object>> demasiadoGrande(MaxUploadSizeExceededException e) {
        long max = e.getMaxUploadSize();
        return cuerpo(HttpStatus.PAYLOAD_TOO_LARGE, "PAYLOAD_TOO_LARGE",
                "El fichero supera el tamaño máximo permitido"
                        + (max > 0 ? " de " + max + " bytes." : "."));
    }

    /**
     * Fallo al subir o al registrar. 502 y no 500: el fallo es del
     * almacén de objetos, no de este servicio, y esa distinción importa
     * cuando alguien mira los logs a las tres de la mañana.
     */
    @ExceptionHandler(TransformadorMultipart.SubidaFallidaException.class)
    public ResponseEntity<Map<String, Object>> subidaFallida(
            TransformadorMultipart.SubidaFallidaException e) {
        log.error("Subida fallida", e);
        return cuerpo(HttpStatus.BAD_GATEWAY, "UPLOAD_FAILED",
                "No se pudo almacenar el fichero. No se creó nada a medias.");
    }

    /**
     * El multipart llegó roto o sin la parte esperada. Es la petición la que
     * está mal formada, no el servidor: sin este brazo la caza-todo lo
     * convertía en un 500 y quien subía el fichero no sabía qué corregir.
     */
    @ExceptionHandler({MultipartException.class, MissingServletRequestPartException.class})
    public ResponseEntity<Map<String, Object>> multipartInvalido(Exception e) {
        log.warn("Multipart inválido: {}", e.getMessage());
        return cuerpo(HttpStatus.BAD_REQUEST, "INVALID_MULTIPART",
                "La petición multipart está incompleta o mal formada. "
                        + "Envía el fichero en una parte del formulario.");
    }

    @ExceptionHandler(MissingServletRequestParameterException.class)
    public ResponseEntity<Map<String, Object>> faltaParametro(
            MissingServletRequestParameterException e) {
        return cuerpo(HttpStatus.BAD_REQUEST, "BAD_REQUEST",
                "Falta el parámetro requerido '" + e.getParameterName() + "'.");
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> argumentoInvalido(IllegalArgumentException e) {
        return cuerpo(HttpStatus.BAD_REQUEST, "BAD_REQUEST",
                e.getMessage() == null ? "Solicitud inválida." : e.getMessage());
    }

    /**
     * El destino al que se reenvía no respondió a tiempo o no se pudo abrir la
     * conexión. 504, no 500: este servicio funciona, el de abajo no contesta.
     */
    @ExceptionHandler(ResourceAccessException.class)
    public ResponseEntity<Map<String, Object>> destinoSinRespuesta(ResourceAccessException e) {
        log.error("Destino inalcanzable al reenviar", e);
        return cuerpo(HttpStatus.GATEWAY_TIMEOUT, "DESTINATION_TIMEOUT",
                "El servicio de destino no respondió a tiempo. El fichero se subió; "
                        + "reintenta la operación.");
    }

    @ExceptionHandler(RestClientException.class)
    public ResponseEntity<Map<String, Object>> destinoFallido(RestClientException e) {
        log.error("Fallo al reenviar al destino", e);
        return cuerpo(HttpStatus.BAD_GATEWAY, "DESTINATION_FAILED",
                "El servicio de destino devolvió una respuesta inesperada.");
    }

    /**
     * Fallos de la tabla {@code tarchivo}. El texto se depura con el mismo
     * {@link SqlErrorSanitizer} que usan query-service y auth-center, para que
     * ningún nombre de tabla o constraint salga en la respuesta.
     */
    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<Map<String, Object>> fallaDatos(DataAccessException e) {
        SQLException sql = e.getMostSpecificCause() instanceof SQLException s ? s : null;
        if (sql == null) {
            log.error("Fallo de acceso a datos", e);
            return cuerpo(HttpStatus.INTERNAL_SERVER_ERROR, SqlErrorKind.INTERNAL.code(),
                    SqlErrorKind.INTERNAL.defaultMessage());
        }
        SqlErrorSanitizer.Sanitized sanitizado = SqlErrorSanitizer.sanitize(sql);
        log.error("Fallo de datos sqlState={}: {}", sanitizado.sqlState(), sql.getMessage(), e);
        HttpStatus status = sanitizado.kind() == SqlErrorKind.UNAVAILABLE
                ? HttpStatus.SERVICE_UNAVAILABLE
                : HttpStatus.INTERNAL_SERVER_ERROR;
        return cuerpo(status, sanitizado.code(), sanitizado.message());
    }

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> estado(ResponseStatusException e) {
        return cuerpo(e.getStatusCode(), e.getStatusCode().toString(),
                e.getReason() == null ? "Error en la solicitud" : e.getReason());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> resto(Exception e) {
        log.error("Error no controlado", e);
        return cuerpo(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR",
                "Error interno del servidor");
    }

    private static ResponseEntity<Map<String, Object>> cuerpo(
            org.springframework.http.HttpStatusCode status, String code, String message) {
        return ResponseEntity.status(status).body(Map.of("code", code, "message", message));
    }
}
