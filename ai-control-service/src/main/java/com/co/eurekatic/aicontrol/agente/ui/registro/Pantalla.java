package com.co.eurekatic.aicontrol.agente.ui.registro;

import java.util.List;
import java.util.Objects;

/**
 * Pantalla a la que el agente puede llevar a alguien: entrada de {@code ai.ruta_ui} con su nombre y URL
 * de TMENU.
 *
 * @param menuPadre nombre del menu que la agrupa; cadena vacia si es de primer nivel
 */
public record Pantalla(String codigo, String menuCodigo, String nombre, String url, String menuPadre,
                       String descripcion, List<String> sinonimos) {

    private static final String SEPARADOR_MIGAS = " › ";

    public Pantalla {
        Objects.requireNonNull(codigo, "codigo");
        Objects.requireNonNull(menuCodigo, "menuCodigo");
        Objects.requireNonNull(nombre, "nombre");
        Objects.requireNonNull(url, "url");
        Objects.requireNonNull(menuPadre, "menuPadre");
        Objects.requireNonNull(descripcion, "descripcion");
        sinonimos = List.copyOf(sinonimos);
    }

    /** Ruta de migas para la persona: "Gestión Académica › Planeador". */
    public String migas() {
        return menuPadre.isBlank() ? nombre : menuPadre + SEPARADOR_MIGAS + nombre;
    }
}
