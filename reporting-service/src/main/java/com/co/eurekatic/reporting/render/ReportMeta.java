package com.co.eurekatic.reporting.render;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Lo que el reporte dice de si mismo: quien lo pidio y con que filtros.
 *
 * <p>El resumen de filtros no es decorativo. Un PDF exportado circula por
 * correo y sobrevive al contexto donde se genero: sin esa linea, quien lo
 * recibe no puede distinguir "el padron completo" de "los de una sola sede",
 * y las dos cosas se ven igual. Imprimir el filtro es lo que hace que el
 * archivo se pueda interpretar solo.
 *
 * @param usuario correo de quien lo genero, o null si no se pudo resolver
 * @param filtros los filtros tal como llegaron del front
 */
public record ReportMeta(String usuario, Map<String, Object> filtros) {

    /** Etiquetas legibles de los filtros que hoy manda el front. */
    private static final Map<String, String> ETIQUETAS = Map.ofEntries(
            Map.entry("search", "Búsqueda"),
            Map.entry("ids", "Selección"),
            Map.entry("roles", "Roles"),
            Map.entry("workSchedules", "Jornadas"),
            Map.entry("statuses", "Estados"),
            Map.entry("campusId", "Sede"),
            Map.entry("department", "Departamento"),
            Map.entry("municipality", "Municipio"),
            Map.entry("status", "Estado"),
            Map.entry("zones", "Zonas"));

    /**
     * Los filtros en una linea, listos para imprimir. Cadena vacia cuando no
     * hay ninguno — y ahi el caller omite la banda entera en vez de dejar un
     * "Filtros aplicados:" colgando sin nada detras.
     */
    public String filtrosLegibles() {
        if (filtros == null || filtros.isEmpty()) {
            return "";
        }

        Map<String, Object> utiles = new LinkedHashMap<>();
        filtros.forEach((clave, valor) -> {
            // Un filtro presente pero vacio es "sin filtrar": ensuciaria la
            // linea con ruido que no cambio el resultado.
            if (valor == null) return;
            if (valor instanceof String s && s.isBlank()) return;
            if (valor instanceof java.util.Collection<?> c && c.isEmpty()) return;
            utiles.put(clave, valor);
        });

        if (utiles.isEmpty()) {
            return "";
        }

        return utiles.entrySet().stream()
                .map(e -> etiqueta(e.getKey()) + ": " + resumir(e.getValue()))
                .collect(Collectors.joining("   ·   "));
    }

    private static String etiqueta(String clave) {
        String conocida = ETIQUETAS.get(clave);
        if (conocida != null) return conocida;
        // Filtro que todavia no tiene etiqueta: se humaniza el nombre en vez
        // de esconderlo. Es preferible un "FechaDesde" imperfecto a que el
        // lector no se entere de que ese filtro existio.
        String separado = clave.replaceAll("([a-z])([A-Z])", "$1 $2");
        return Character.toUpperCase(separado.charAt(0)) + separado.substring(1);
    }

    /**
     * Una lista larga de ids no aporta nada impreso —nadie lee 40 numeros—,
     * pero SI importa saber que el reporte salio de una seleccion manual y de
     * cuantos elementos.
     */
    private static String resumir(Object valor) {
        if (valor instanceof java.util.Collection<?> c) {
            if (c.size() > 6) {
                return c.size() + " elementos seleccionados";
            }
            return c.stream().map(CellValues::toText).collect(Collectors.joining(", "));
        }
        return CellValues.toText(valor);
    }
}
