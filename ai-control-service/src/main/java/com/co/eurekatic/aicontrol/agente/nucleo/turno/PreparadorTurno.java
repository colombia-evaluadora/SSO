package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.RouterIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.Evaluacion;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.EvaluadorEntrada;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService.RegistroEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.limite.LimitadorPorUsuario;
import org.springframework.stereotype.Component;

import java.time.Duration;
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

    public PreparadorTurno(LimitadorPorUsuario limitador, EvaluadorEntrada evaluador, RouterIntencion router,
                           SelectorHerramientas selector, EventoSeguridadService eventos) {
        this.limitador = limitador;
        this.evaluador = evaluador;
        this.router = router;
        this.selector = selector;
        this.eventos = eventos;
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
        Intencion intencion = router.clasificar(evaluacion.textoNormalizado(), evaluacion.riesgo());
        SelectorHerramientas.Seleccion seleccion = selector.para(usuario, intencion);
        return new Preparacion.Listo(evaluacion.textoNormalizado(), intencion,
                seleccion.herramientas(), seleccion.callbacks());
    }

    private void registrarBloqueo(UUID conversacionId, UsuarioAgente usuario, Evaluacion evaluacion) {
        Optional<RegistroEvento> evento = evaluacion.hallazgo().map(h -> new RegistroEvento(
                Optional.of(conversacionId), usuario.userId(), h, Optional.of(evaluacion.textoNormalizado())));
        evento.ifPresent(eventos::registrar);
    }
}
