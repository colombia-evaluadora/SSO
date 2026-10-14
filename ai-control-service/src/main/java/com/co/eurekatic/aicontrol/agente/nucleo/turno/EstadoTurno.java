package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.TipoRespuesta;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;

import java.util.Set;

/**
 * Maquina de estados de un turno (seccion 4.5 de la propuesta). Sirve para registrar el recorrido en
 * logs y metricas; nunca lleva contenido. Desde cualquier estado no terminal se puede pasar a
 * BLOQUEADO o a SIN_PERMISO.
 *
 * <p>Cada constante declara de que estados puede venir. Los estados terminales no tienen salida.
 */
public enum EstadoTurno {

    RECIBIDO,
    VALIDADO(RECIBIDO),
    INTENCION(VALIDADO),
    PERMISO_OK(INTENCION),
    RECOLECTANDO(PERMISO_OK),
    PREGUNTA(RECOLECTANDO),
    PENDIENTE_CONFIRMACION(RECOLECTANDO),
    RESPUESTA(RECOLECTANDO),
    BLOQUEADO,
    SIN_PERMISO,
    EJECUTADA(PENDIENTE_CONFIRMACION),
    FALLIDA(PENDIENTE_CONFIRMACION),
    DESCARTADA(PENDIENTE_CONFIRMACION),
    EXPIRADA(PENDIENTE_CONFIRMACION);

    private static final Set<EstadoTurno> TERMINALES = Set.of(PREGUNTA, RESPUESTA, BLOQUEADO, SIN_PERMISO,
            EJECUTADA, FALLIDA, DESCARTADA, EXPIRADA);

    private final Set<EstadoTurno> previos;

    EstadoTurno(EstadoTurno... previos) {
        this.previos = Set.of(previos);
    }

    /** true si el recorrido no puede seguir desde este estado. */
    public boolean terminal() {
        return TERMINALES.contains(this);
    }

    /** Si el recorrido puede pasar de este estado al nuevo. */
    public boolean puedePasarA(EstadoTurno nuevo) {
        if (terminal()) {
            return false;
        }
        if (nuevo == BLOQUEADO || nuevo == SIN_PERMISO) {
            return true;
        }
        return nuevo.previos.contains(this);
    }

    /** Estado del turno que corresponde a una respuesta ya generada. */
    public static EstadoTurno de(TipoRespuesta tipo) {
        return switch (tipo) {
            case RESPUESTA, UI, DATOS -> RESPUESTA;
            case PREGUNTA -> PREGUNTA;
            case CONFIRMACION -> PENDIENTE_CONFIRMACION;
            case BLOQUEADO -> BLOQUEADO;
            case SIN_PERMISO -> SIN_PERMISO;
        };
    }

    /** Estado de una accion de escritura: pendiente, o el estado final al confirmarla o cancelarla. */
    public static EstadoTurno de(EstadoAccion estado) {
        return switch (estado) {
            case PENDIENTE -> PENDIENTE_CONFIRMACION;
            case EJECUTADA -> EJECUTADA;
            case FALLIDA -> FALLIDA;
            case DESCARTADA -> DESCARTADA;
            case EXPIRADA -> EXPIRADA;
        };
    }
}
