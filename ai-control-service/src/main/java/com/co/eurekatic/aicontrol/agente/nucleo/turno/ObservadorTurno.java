package com.co.eurekatic.aicontrol.agente.nucleo.turno;

/**
 * Recibe cada paso de un turno mientras ocurre; lo usa el streaming para mostrar "Analizando..." sin
 * esperar a la respuesta. Recibe el estado, las herramientas que se ejecutan (codigo y etiqueta, nunca sus
 * argumentos ni su resultado). No debe lanzar: un fallo
 * al avisar no puede romper el turno.
 */
@FunctionalInterface
public interface ObservadorTurno {

    ObservadorTurno NINGUNO = estado -> {
    };

    void alPasar(EstadoTurno estado);

    /** Una herramienta empieza o termina. */
    default void alHerramienta(EventoHerramienta evento) {
    }
}
