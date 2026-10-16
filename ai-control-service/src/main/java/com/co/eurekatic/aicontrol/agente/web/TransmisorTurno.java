package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.AgenteService;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.EstadoTurno;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.EventoHerramienta;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.ObservadorTurno;
import com.co.eurekatic.aicontrol.agente.web.dto.EventoHerramientaDto;
import com.co.eurekatic.aicontrol.agente.web.dto.EventoStreamDto;
import com.co.eurekatic.aicontrol.agente.web.dto.RespuestaDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.springframework.beans.factory.annotation.Autowired;
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
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Un turno por Server-Sent Events: emite {@code estado} en cada paso y {@code herramienta} al empezar y
 * terminar cada herramienta (para que el front muestre
 * "Analizando..." mientras el razonador trabaja), y al final {@code respuesta} con el mismo cuerpo que el
 * endpoint sincrono, o {@code error} con el estado HTTP que habria tenido. Nunca emite contenido
 * intermedio del modelo ni su razonamiento.
 */
@Component
public class TransmisorTurno implements DisposableBean {

    static final String EVENTO_ESTADO = "estado";
    static final String EVENTO_RESPUESTA = "respuesta";
    static final String EVENTO_ERROR = "error";
    static final String EVENTO_HERRAMIENTA = "herramienta";
    private static final String MENSAJE_GENERICO = "No se pudo completar la operación.";
    private static final Logger log = LoggerFactory.getLogger(TransmisorTurno.class);

    private final AgenteService agente;
    private final Duration timeout;
    private final ExecutorService hilos = Executors.newVirtualThreadPerTaskExecutor();

    @Autowired
    public TransmisorTurno(AgenteService agente, AgenteProperties props) {
        this(agente, props.limites().streamTimeout());
    }

    TransmisorTurno(AgenteService agente, Duration timeout) {
        this.agente = agente;
        this.timeout = timeout;
    }

    public SseEmitter transmitir(UUID conversacionId, UsuarioAgente usuario, String texto, String contextoUiJson) {
        SseEmitter emisor = new SseEmitter(timeout.toMillis());
        Flujo flujo = new Flujo(emisor, conversacionId, usuario);
        // Conexion cerrada o vencida antes de terminar: el turno se corta y libera la reserva del usuario.
        emisor.onError(e -> flujo.cancelarSiSigue());
        emisor.onTimeout(flujo::cancelarSiSigue);
        hilos.execute(() -> ejecutar(flujo, texto, contextoUiJson));
        return emisor;
    }

    private void ejecutar(Flujo flujo, String texto, String contextoUiJson) {
        try {
            RespuestaAgente respuesta = agente.procesar(flujo.conversacionId, flujo.usuario, texto, contextoUiJson,
                    flujo);
            flujo.enviar(EVENTO_RESPUESTA, RespuestaDto.de(respuesta));
        } catch (ErrorAgente e) {
            flujo.enviar(EVENTO_ERROR, EventoStreamDto.error(ManejadorErrores.estado(e).value(), e.getMessage()));
        } catch (ResponseStatusException e) {
            flujo.enviar(EVENTO_ERROR, EventoStreamDto.error(e.getStatusCode().value(),
                    e.getReason() == null ? MENSAJE_GENERICO : e.getReason()));
        } catch (RuntimeException e) {
            log.error("Fallo el turno por streaming: conversacion={} error={}", flujo.conversacionId,
                    e.getClass().getSimpleName());
            flujo.enviar(EVENTO_ERROR, EventoStreamDto.error(HttpStatus.INTERNAL_SERVER_ERROR.value(), MENSAJE_GENERICO));
        } finally {
            flujo.terminado.set(true);
            flujo.emisor.complete();
        }
    }

    /** Un flujo SSE abierto: observa el turno y lo cancela si la persona se va antes de que termine. */
    private final class Flujo implements ObservadorTurno {

        private final SseEmitter emisor;
        private final UUID conversacionId;
        private final UsuarioAgente usuario;
        private final AtomicBoolean terminado = new AtomicBoolean();
        private final AtomicBoolean cancelado = new AtomicBoolean();

        private Flujo(SseEmitter emisor, UUID conversacionId, UsuarioAgente usuario) {
            this.emisor = emisor;
            this.conversacionId = conversacionId;
            this.usuario = usuario;
        }

        @Override
        public void alPasar(EstadoTurno estado) {
            enviar(EVENTO_ESTADO, EventoStreamDto.estado(estado.name()));
        }

        @Override
        public void alHerramienta(EventoHerramienta evento) {
            enviar(EVENTO_HERRAMIENTA, EventoHerramientaDto.de(evento));
        }

        /** Si la persona cerro la conexion, el turno se cancela; el envio fallido no rompe nada. */
        void enviar(String evento, Object datos) {
            try {
                emisor.send(SseEmitter.event().name(evento).data(datos, MediaType.APPLICATION_JSON));
            } catch (IOException | IllegalStateException e) {
                log.debug("No se pudo emitir {}: {}", evento, e.getClass().getSimpleName());
                cancelarSiSigue();
            }
        }

        void cancelarSiSigue() {
            if (terminado.get() || !cancelado.compareAndSet(false, true)) {
                return;
            }
            try {
                if (agente.cancelar(conversacionId, usuario)) {
                    log.info("Turno cancelado por desconexion: conversacion={}", conversacionId);
                }
            } catch (RuntimeException e) {
                log.debug("No se pudo cancelar el turno: {}", e.getClass().getSimpleName());
            }
        }
    }

    @Override
    public void destroy() {
        hilos.close();
    }
}
