package com.co.eurekatic.aicontrol.agente.ui.contexto;

import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/**
 * Lo que el front cuenta de la pantalla en cada mensaje: donde esta la persona, que formularios tiene
 * abiertos y que filtros admite el listado. Dato no confiable; nunca decide permisos.
 *
 * @param ruta        ruta actual del front; cadena vacia si no la manda
 * @param formularios formularios abiertos
 * @param filtros     nombres de filtro que el listado abierto acepta
 */
public record ContextoUi(String ruta, List<FormularioUi> formularios, Set<String> filtros) {

    private static final ContextoUi VACIO = new ContextoUi("", List.of(), Set.of());

    public ContextoUi {
        Objects.requireNonNull(ruta, "ruta");
        formularios = List.copyOf(formularios);
        filtros = Set.copyOf(filtros);
    }

    public static ContextoUi vacio() {
        return VACIO;
    }

    public Optional<FormularioUi> formulario(String codigo) {
        return formularios.stream().filter(f -> f.codigo().equals(codigo)).findFirst();
    }
}
