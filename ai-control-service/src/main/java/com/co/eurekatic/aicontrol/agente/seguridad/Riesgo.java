package com.co.eurekatic.aicontrol.agente.seguridad;

/**
 * Nivel de riesgo de un mensaje o de una respuesta. El orden importa: el
 * riesgo final de un turno es el maximo de los filtros que lo revisaron.
 *
 * <p>ALTO bloquea el turno; MEDIO lo deja seguir pero sin escrituras, sin SQL
 * de nivel 2 ni acciones de UI.
 */
public enum Riesgo {
    BAJO,
    MEDIO,
    ALTO;

    public Riesgo max(Riesgo otro) {
        return compareTo(otro) >= 0 ? this : otro;
    }
}
