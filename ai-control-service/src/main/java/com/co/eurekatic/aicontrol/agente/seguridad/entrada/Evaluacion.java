package com.co.eurekatic.aicontrol.agente.seguridad.entrada;

import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;

import java.util.Optional;

/**
 * Veredicto combinado de la entrada: firewall y clasificador.
 *
 * @param permitido        false si el turno debe detenerse aqui
 * @param textoNormalizado texto tras el firewall, para auditar por huella
 * @param hallazgo         el de mayor riesgo; vacio si la entrada es BAJO
 */
public record Evaluacion(boolean permitido, String textoNormalizado, Optional<Hallazgo> hallazgo) {

    /** Riesgo final de la entrada; BAJO si no hubo hallazgo. */
    public Riesgo riesgo() {
        return hallazgo.map(Hallazgo::riesgo).orElse(Riesgo.BAJO);
    }
}
