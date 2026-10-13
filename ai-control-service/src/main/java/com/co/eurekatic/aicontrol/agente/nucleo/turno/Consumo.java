package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import java.util.Objects;

/**
 * Lo que costo generar una respuesta, para guardarlo con el mensaje.
 *
 * @param uso        tokens consumidos en el turno
 * @param modelo     modelo que contesto; cadena vacia si el turno no llamo al modelo
 * @param latenciaMs tiempo del turno, en milisegundos
 */
public record Consumo(Uso uso, String modelo, long latenciaMs) {

    /** Un turno sin llamada al modelo (bloqueos, permisos, confirmaciones). */
    public static final Consumo NINGUNO = new Consumo(Uso.NINGUNO, "", 0L);

    public Consumo {
        Objects.requireNonNull(uso, "uso");
        Objects.requireNonNull(modelo, "modelo");
    }
}
