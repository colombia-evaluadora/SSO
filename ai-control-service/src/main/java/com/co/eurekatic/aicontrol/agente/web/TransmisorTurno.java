package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.AgenteService;
import com.co.eurekatic.aicontrol.agente.web.dto.EventoStreamDto;
import com.co.eurekatic.aicontrol.agente.web.dto.RespuestaDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

import java.io.IOException;
import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Un turno por Server-Sent Events: emite {@code estado} en cada paso (para que el front muestre
 * "Analizando..." mientras el razonador trabaja), y al final {@code respuesta} con el mismo cuerpo que el
 * endpoint sincrono, o {@code error} con el estado HTTP que habria tenido. Nunca emite contenido
 * intermedio del modelo ni su razonamiento.
 */
@Component
public class TransmisorTurno implements DisposableBean {

    static final String EVENTO_ESTADO = "estado";
    static final String EVENTO_RESPUESTA = "respuesta";
    static final String EVENTO_ERROR = "error";
    private static final String MENSAJE_GENERICO = "No se pudo completar la operación.";
    private static final Logger log = LoggerFactory.getLogger(TransmisorTurno.class);

    private final AgenteService agente;
    private final Duration timeout;
    private final ExecutorService hilos = Executors.newVirtualThreadPerTaskExecutor();

    public TransmisorTurno(AgenteService agente,
                           @Value("${sso.ai.agente.stream-timeout:PT150S}") Duration timeout) {
        this.agente = agente;
        this.timeout = timeout;
    }

    public SseEmitter transmitir(UUID conversacionId, UsuarioAgente usuario, String texto, String contextoUiJson) {
        SseEmitter emisor = new SseEmitter(timeout.toMillis());
        hilos.execute(() -> ejecutar(emisor, conversacionId, usuario, texto, contextoUiJson));
        return emisor;
    }

    private void ejecutar(SseEmitter emisor, UUID conversacionId, UsuarioAgente usuario, String texto,
                          String contextoUiJson) {
        try {
            RespuestaAgente respuesta = agente.procesar(conversacionId, usuario, texto, contextoUiJson,
                    estado -> enviar(emisor, EVENTO_ESTADO, EventoStreamDto.estado(estado.name())));
            enviar(emisor, EVENTO_RESPUESTA, RespuestaDto.de(respuesta));
        } catch (ErrorAgente e) {
            enviar(emisor, EVENTO_ERROR, EventoStreamDto.error(ManejadorErrores.estado(e).value(), e.getMessage()));
        } catch (ResponseStatusException e) {
            enviar(emisor, EVENTO_ERROR, EventoStreamDto.error(e.getStatusCode().value(),
                    e.getReason() == null ? MENSAJE_GENERICO : e.getReason()));
        } catch (RuntimeException e) {
            log.error("Fallo el turno por streaming: conversacion={} error={}", conversacionId, e.getClass().getSimpleName());
            enviar(emisor, EVENTO_ERROR, EventoStreamDto.error(HttpStatus.INTERNAL_SERVER_ERROR.value(), MENSAJE_GENERICO));
        } finally {
            emisor.complete();
        }
    }

    /** Si la persona cerro la conexion no hay nada que hacer: el turno sigue y queda en el historial. */
    private static void enviar(SseEmitter emisor, String evento, Object datos) {
        try {
            emisor.send(SseEmitter.event().name(evento).data(datos, MediaType.APPLICATION_JSON));
        } catch (IOException | IllegalStateException e) {
            log.debug("No se pudo emitir {}: {}", evento, e.getClass().getSimpleName());
        }
    }

    @Override
    public void destroy() {
        hilos.close();
    }
}
