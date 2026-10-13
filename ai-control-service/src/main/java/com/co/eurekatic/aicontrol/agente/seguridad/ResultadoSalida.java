package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.List;
import java.util.Objects;

/**
 * Texto final del agente tras la revision de salida.
 *
 * @param texto      lo que se devuelve al usuario
 * @param hallazgos  lo que se cambio o bloqueo; vacia si la salida sale tal cual
 */
public record ResultadoSalida(String texto, List<Hallazgo> hallazgos) {

    public ResultadoSalida {
        Objects.requireNonNull(texto, "texto");
        hallazgos = List.copyOf(hallazgos);
    }

    /** true si se cambio algo: bloqueo completo o redaccion. */
    public boolean redactado() {
        return !hallazgos.isEmpty();
    }

    /** Riesgo maximo de los hallazgos; BAJO si no hay ninguno. */
    public Riesgo riesgo() {
        return hallazgos.stream().map(Hallazgo::riesgo).reduce(Riesgo.BAJO, Riesgo::max);
    }

    /** Motivos sin duplicados, en orden de deteccion. */
    public List<Motivo> motivos() {
        return hallazgos.stream().map(Hallazgo::motivo).distinct().toList();
    }
}
