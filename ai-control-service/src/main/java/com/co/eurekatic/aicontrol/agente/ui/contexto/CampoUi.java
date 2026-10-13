package com.co.eurekatic.aicontrol.agente.ui.contexto;

import java.util.List;
import java.util.Objects;

/**
 * Campo de un formulario abierto, segun el front. Es un dato no confiable: dice que hay en pantalla,
 * no que esta permitido.
 *
 * @param opciones opciones visibles de un campo de seleccion; vacio en los demas
 * @param lleno    si el campo ya tiene valor (el agente no vuelve a preguntarlo)
 */
public record CampoUi(String nombre, String etiqueta, TipoCampo tipo, boolean obligatorio,
                      List<Opcion> opciones, boolean lleno) {

    public CampoUi {
        Objects.requireNonNull(nombre, "nombre");
        Objects.requireNonNull(etiqueta, "etiqueta");
        Objects.requireNonNull(tipo, "tipo");
        opciones = List.copyOf(opciones);
    }

    /** Si el valor cumple el tipo y, en una seleccion con opciones, si es una de ellas. */
    public boolean admite(Object valor) {
        if (!tipo.admite(valor)) {
            return false;
        }
        return tipo != TipoCampo.SELECCION || opciones.isEmpty()
                || opciones.stream().anyMatch(o -> o.valor().equals(String.valueOf(valor)));
    }

    public record Opcion(String valor, String etiqueta) {
        public Opcion {
            Objects.requireNonNull(valor, "valor");
            Objects.requireNonNull(etiqueta, "etiqueta");
        }
    }
}
