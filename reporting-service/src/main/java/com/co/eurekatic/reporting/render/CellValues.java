package com.co.eurekatic.reporting.render;

import java.time.temporal.TemporalAccessor;
import java.util.Collection;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Convierte el valor crudo de una celda al texto que se imprime.
 *
 * <p>Existe porque las filas llegan como JSON deserializado y no todo
 * es una cadena. Varias funciones de listado devuelven columnas
 * agregadas —{@code roles}, {@code sedes}, {@code estados_permisos}—
 * como arrays u objetos JSON. Impresas tal cual saldrian con el
 * {@code toString()} de Java: {@code [{nombre=Rector, id=14}]}, que no
 * es algo que se pueda poner delante de un usuario.
 *
 * <p>La misma conversion se usa para PDF y para Excel, asi que las dos
 * exportaciones del mismo dato dicen lo mismo.
 */
final class CellValues {

    private CellValues() {}

    static String toText(Object value) {
        return switch (value) {
            case null -> "";
            case String s -> s;
            case Boolean b -> b ? "Si" : "No";
            case TemporalAccessor t -> t.toString();
            // Una lista se lee mejor separada por comas que con
            // corchetes; se aplica recursivo porque los elementos suelen
            // ser objetos ({nombre: "..."}).
            case Collection<?> c -> c.stream()
                    .map(CellValues::toText)
                    .filter(s -> !s.isBlank())
                    .collect(Collectors.joining(", "));
            // De un objeto JSON interesa la etiqueta, no el id interno:
            // se busca la primera clave con pinta de nombre y, si no hay,
            // se cae a los valores concatenados.
            case Map<?, ?> m -> mapToText(m);
            default -> String.valueOf(value);
        };
    }

    private static String mapToText(Map<?, ?> m) {
        for (String candidata : new String[]{"nombre", "label", "name", "descripcion", "titulo"}) {
            Object v = m.get(candidata);
            if (v != null) {
                return toText(v);
            }
        }
        return m.values().stream()
                .map(CellValues::toText)
                .filter(s -> !s.isBlank())
                .collect(Collectors.joining(" · "));
    }

    /**
     * Para Excel conviene conservar el numero como numero (para que la
     * celda sume y ordene bien) y mandar todo lo demas como texto.
     */
    static Double asNumber(Object value) {
        if (value instanceof Number n) {
            return n.doubleValue();
        }
        return null;
    }
}
