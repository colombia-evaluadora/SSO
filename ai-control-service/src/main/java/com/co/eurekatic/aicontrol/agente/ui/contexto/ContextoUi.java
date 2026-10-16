package com.co.eurekatic.aicontrol.agente.ui.contexto;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/**
 * Lo que el front cuenta de la pantalla en cada mensaje: donde esta la persona, que formularios tiene
 * abiertos, que filtros admite el listado y los parametros de la pantalla. Dato no confiable; nunca decide
 * permisos.
 *
 * @param ruta        ruta actual del front; cadena vacia si no la manda
 * @param formularios formularios abiertos
 * @param filtros     nombres de filtro que el listado abierto acepta
 * @param parametros  parametros de la pantalla (ids de la URL, filtros aplicados, pestana...), clave a valor
 */
public record ContextoUi(String ruta, List<FormularioUi> formularios, Set<String> filtros,
                         Map<String, String> parametros) {

    private static final ContextoUi VACIO = new ContextoUi("", List.of(), Set.of(), Map.of());

    public ContextoUi {
        Objects.requireNonNull(ruta, "ruta");
        formularios = List.copyOf(formularios);
        filtros = Set.copyOf(filtros);
        // Conserva el orden en que llegaron.
        parametros = parametros == null ? Map.of() : Collections.unmodifiableMap(new LinkedHashMap<>(parametros));
    }

    public ContextoUi(String ruta, List<FormularioUi> formularios, Set<String> filtros) {
        this(ruta, formularios, filtros, Map.of());
    }

    public static ContextoUi vacio() {
        return VACIO;
    }

    public Optional<FormularioUi> formulario(String codigo) {
        return formularios.stream().filter(f -> f.codigo().equals(codigo)).findFirst();
    }
}
