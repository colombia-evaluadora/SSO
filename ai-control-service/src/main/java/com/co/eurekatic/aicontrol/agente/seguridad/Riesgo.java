package com.co.eurekatic.aicontrol.agente.seguridad;

/**
 * Nivel de riesgo de un mensaje o de una respuesta. El riesgo final de un turno
 * es el maximo de los filtros que lo revisaron.
 *
 * <p>ALTO corta el turno. MEDIO lo deja seguir sin escrituras ni acciones de UI.
 */
public enum Riesgo {
    BAJO,
    MEDIO,
    ALTO;

    public Riesgo max(Riesgo otro) {
        return compareTo(otro) >= 0 ? this : otro;
    }

    /** Un riesgo ALTO corta el turno antes de llamar al modelo. */
    public boolean bloquea() {
        return this == ALTO;
    }

    /** Solo un turno de riesgo BAJO puede proponer escrituras o acciones de UI. */
    public boolean permiteEscritura() {
        return this == BAJO;
    }
}
