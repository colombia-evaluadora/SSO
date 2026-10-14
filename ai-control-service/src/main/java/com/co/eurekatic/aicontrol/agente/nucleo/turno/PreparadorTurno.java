package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.InvocadorHerramientas;
import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.RouterIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.Evaluacion;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.EvaluadorEntrada;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService.RegistroEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.limite.LimitadorPorUsuario;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Lo que pasa antes de tocar el modelo razonador: limite por usuario, seguridad de la entrada,
 * intencion y herramientas del turno. Un ALTO se registra y corta aqui.
 */
@Component
public class PreparadorTurno {

    static final String MENSAJE_BLOQUEO = "No puedo procesar ese mensaje. ¿En qué más puedo ayudarte con el colegio?";
    static final Duration VENTANA_LIMITE = Duration.ofMinutes(1);

    private final LimitadorPorUsuario limitador;
    private final EvaluadorEntrada evaluador;
    private final RouterIntencion router;
    private final SelectorHerramientas selector;
    private final EventoSeguridadService eventos;
    private final MensajeStore mensajes;

    public PreparadorTurno(LimitadorPorUsuario limitador, EvaluadorEntrada evaluador, RouterIntencion router,
                           SelectorHerramientas selector, EventoSeguridadService eventos, MensajeStore mensajes) {
        this.limitador = limitador;
        this.evaluador = evaluador;
        this.router = router;
        this.selector = selector;
        this.eventos = eventos;
        this.mensajes = mensajes;
    }

    /**
     * @throws ErrorAgente.LimiteExcedido si el usuario supera sus turnos por minuto
     */
    public Preparacion preparar(UUID conversacionId, UsuarioAgente usuario, String texto) {
        if (!limitador.permitir(usuario.userId())) {
            throw new ErrorAgente.LimiteExcedido(VENTANA_LIMITE);
        }
        Evaluacion evaluacion = evaluador.evaluar(texto);
        if (!evaluacion.permitido()) {
            registrarBloqueo(conversacionId, usuario, evaluacion);
            return new Preparacion.Bloqueada(new RespuestaAgente.Bloqueado(MENSAJE_BLOQUEO));
        }
        Intencion intencion = continuacion(conversacionId,
                router.clasificar(evaluacion.textoNormalizado(), evaluacion.riesgo()));
        SelectorHerramientas.Seleccion seleccion = selector.para(usuario, intencion);
        return new Preparacion.Listo(evaluacion.textoNormalizado(), intencion,
                seleccion.herramientas(), seleccion.callbacks(), seleccion.menus());
    }

    /**
     * El router ve el mensaje suelto: "el peso es 100%" o "usa los valores por defecto" le parecen charla, y
     * sin escrituras ofrecidas el modelo no puede rehacer la accion. Si el agente acaba de preguntar, de
     * proponer o de fallar al confirmar, el mensaje sigue esa accion: pasa a ACCION con el mismo riesgo.
     */
    Intencion continuacion(UUID conversacionId, Intencion intencion) {
        boolean consultaOCharla = intencion.tipo() == TipoIntencion.CONSULTA || intencion.tipo() == TipoIntencion.CHARLA;
        if (!consultaOCharla || !sigueUnaAccion(conversacionId)) {
            return intencion;
        }
        return new Intencion(TipoIntencion.ACCION, intencion.accion(), intencion.confianza(), intencion.riesgo());
    }

    private boolean sigueUnaAccion(UUID conversacionId) {
        List<MensajeStore.Mensaje> finales = mensajes.listarFinales(conversacionId);
        for (int i = finales.size() - 1; i >= 0; i--) {
            MensajeStore.Mensaje m = finales.get(i);
            if (m.rol() == RolMensaje.ASSISTANT) {
                return esContinuable(m.tipoRespuesta(), m.contenido());
            }
        }
        return false;
    }

    static boolean esContinuable(String tipoRespuesta, String contenido) {
        if ("PREGUNTA".equals(tipoRespuesta) || "CONFIRMACION".equals(tipoRespuesta)) {
            return true;
        }
        return contenido != null && InvocadorHerramientas.PREFIJOS_RECHAZO.stream().anyMatch(contenido::startsWith);
    }

    private void registrarBloqueo(UUID conversacionId, UsuarioAgente usuario, Evaluacion evaluacion) {
        Optional<RegistroEvento> evento = evaluacion.hallazgo().map(h -> new RegistroEvento(
                Optional.of(conversacionId), usuario.userId(), h, Optional.of(evaluacion.textoNormalizado())));
        evento.ifPresent(eventos::registrar);
    }
}
