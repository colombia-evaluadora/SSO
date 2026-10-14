package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.Objects;
import java.util.Optional;

/**
 * Un filtro encontro algo de riesgo MEDIO o ALTO. El riesgo BAJO no es hallazgo:
 * se expresa con ausencia ({@code Optional.empty()}).
 *
 * @param capa    filtro que lo encontro
 * @param riesgo  MEDIO o ALTO
 * @param motivo  codigo de baja cardinalidad
 */
public record Hallazgo(CapaSeguridad capa, Riesgo riesgo, Motivo motivo) {

    public Hallazgo {
        Objects.requireNonNull(capa, "capa");
        Objects.requireNonNull(motivo, "motivo");
        if (riesgo == null || riesgo == Riesgo.BAJO) {
            throw new IllegalArgumentException("Un hallazgo es de riesgo MEDIO o ALTO");
        }
    }

    /** El de mayor riesgo; ante empate, el primero. */
    public static Optional<Hallazgo> mayor(Optional<Hallazgo> primero, Optional<Hallazgo> segundo) {
        if (primero.isEmpty()) {
            return segundo;
        }
        if (segundo.isEmpty()) {
            return primero;
        }
        return segundo.get().riesgo().compareTo(primero.get().riesgo()) > 0 ? segundo : primero;
    }
}
