package com.co.eurekatic.aicontrol.agente.nucleo;

import java.util.List;
import java.util.Objects;

/**
 * Dato que falta para una accion y la pregunta que se le hace a la persona.
 *
 * @param campo    nombre del dato, tal como lo entiende el formulario
 * @param pregunta texto de la pregunta
 * @param opciones valores posibles, si la respuesta es cerrada; vacia si es libre
 */
public record Faltante(String campo, String pregunta, List<String> opciones) {

    public Faltante {
        Objects.requireNonNull(campo, "campo");
        Objects.requireNonNull(pregunta, "pregunta");
        opciones = List.copyOf(opciones);
    }
}
