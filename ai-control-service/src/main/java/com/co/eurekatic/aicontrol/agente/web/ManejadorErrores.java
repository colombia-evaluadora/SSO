package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.web.dto.ErrorDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

/**
 * Traduce los errores del agente a HTTP. Solo cubre los controllers del agente. Las excepciones de
 * dominio se traducen con un switch exhaustivo: un tipo nuevo no compila hasta tener su estado.
 */
@RestControllerAdvice(assignableTypes = AgenteController.class)
public class ManejadorErrores {

    private static final String MENSAJE_PETICION = "El mensaje no es válido.";
    private static final String MENSAJE_GENERICO = "No se pudo completar la operación.";
    private static final Logger log = LoggerFactory.getLogger(ManejadorErrores.class);

    @ExceptionHandler(ErrorAgente.class)
    public ResponseEntity<ErrorDto> dominio(ErrorAgente error) {
        HttpHeaders cabeceras = new HttpHeaders();
        if (error instanceof ErrorAgente.LimiteExcedido limite) {
            cabeceras.set(HttpHeaders.RETRY_AFTER, String.valueOf(limite.reintentoEn().toSeconds()));
        }
        return ResponseEntity.status(estado(error)).headers(cabeceras).body(new ErrorDto(error.getMessage()));
    }

    /** Estado HTTP de cada error de dominio; lo reutiliza el streaming para su evento de error. */
    public static HttpStatus estado(ErrorAgente error) {
        return switch (error) {
            case ErrorAgente.ConversacionNoEncontrada _ -> HttpStatus.NOT_FOUND;
            case ErrorAgente.AccionNoEncontrada _ -> HttpStatus.NOT_FOUND;
            case ErrorAgente.ConversacionCerrada _ -> HttpStatus.CONFLICT;
            case ErrorAgente.AccionNoPendiente _ -> HttpStatus.CONFLICT;
            case ErrorAgente.AccionAlterada _ -> HttpStatus.CONFLICT;
            case ErrorAgente.AccionExpirada _ -> HttpStatus.GONE;
            case ErrorAgente.LimiteExcedido _ -> HttpStatus.TOO_MANY_REQUESTS;
            case ErrorAgente.SinIdentidad _ -> HttpStatus.FORBIDDEN;
            case ErrorAgente.PeticionInvalida _ -> HttpStatus.BAD_REQUEST;
            case ErrorAgente.TurnoEnCurso _ -> HttpStatus.CONFLICT;
        };
    }

    /** Un fallo de la base no se cuenta al cliente: su mensaje puede llevar SQL o nombres internos. */
    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<ErrorDto> base(DataAccessException error) {
        log.error("Fallo de acceso a datos del agente: {}", error.getClass().getSimpleName());
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(new ErrorDto(MENSAJE_GENERICO));
    }

    /** Errores del modelo o del query-service que llegan ya con estado HTTP (cupo, circuito, timeout). */
    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<ErrorDto> proveedor(ResponseStatusException error) {
        String mensaje = error.getReason() == null ? MENSAJE_GENERICO : error.getReason();
        return ResponseEntity.status(error.getStatusCode()).headers(error.getHeaders()).body(new ErrorDto(mensaje));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ErrorDto> peticionInvalida(MethodArgumentNotValidException error) {
        return ResponseEntity.badRequest().body(new ErrorDto(MENSAJE_PETICION));
    }
}
