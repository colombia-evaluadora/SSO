package com.co.eurekatic.aicontrol.agente.ui.registro;

import com.co.eurekatic.aicontrol.agente.ui.contexto.OrigenFormulario;

import java.util.Objects;
import java.util.Optional;

/**
 * Formulario que el agente puede rellenar, segun {@code ai.ui_formulario}. Un formulario que no esta
 * aqui no se toca aunque el front lo mande.
 *
 * @param camposFuente        en origen DB, codigo de la herramienta de lectura que da su configuracion;
 *                            cadena vacia en FRONT
 * @param herramientaEscritura herramienta que hace lo mismo por accion directa; cadena vacia si no hay
 */
public record FormularioRegistrado(String codigo, String menuCodigo, OrigenFormulario origen,
                                   String camposFuente, String herramientaEscritura) {

    public FormularioRegistrado {
        Objects.requireNonNull(codigo, "codigo");
        Objects.requireNonNull(menuCodigo, "menuCodigo");
        Objects.requireNonNull(origen, "origen");
        Objects.requireNonNull(camposFuente, "camposFuente");
        Objects.requireNonNull(herramientaEscritura, "herramientaEscritura");
        if (origen == OrigenFormulario.DB && camposFuente.isBlank()) {
            throw new IllegalArgumentException("un formulario de origen DB necesita su fuente de campos: " + codigo);
        }
    }

    public Optional<String> fuenteDeCampos() {
        return camposFuente.isBlank() ? Optional.empty() : Optional.of(camposFuente);
    }
}
