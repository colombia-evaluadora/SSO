package com.co.eurekatic.aicontrol.agente.persistencia.accion;

/**
 * Estado de una accion de escritura a la espera de confirmacion, como lo guarda
 * {@code ai.accion_pendiente}. Solo PENDIENTE cambia: los demas son finales.
 */
public enum EstadoAccion {
    PENDIENTE,
    EJECUTADA,
    FALLIDA,
    DESCARTADA,
    EXPIRADA;

    /** La unica transicion del ciclo: de PENDIENTE a cualquier estado final. */
    public boolean puedePasarA(EstadoAccion nuevo) {
        return this == PENDIENTE && nuevo != PENDIENTE;
    }
}
