package com.co.eurekatic.aicontrol.agente.nucleo.turno;

/**
 * Recibe cada paso de un turno mientras ocurre; lo usa el streaming para mostrar "Analizando..." sin
 * esperar a la respuesta. Nunca recibe contenido, solo el estado. No debe lanzar: un fallo al avisar no
 * puede romper el turno.
 */
@FunctionalInterface
public interface ObservadorTurno {

    ObservadorTurno NINGUNO = estado -> {
    };

    void alPasar(EstadoTurno estado);
}
