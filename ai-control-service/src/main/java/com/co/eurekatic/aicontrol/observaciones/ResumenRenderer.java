package com.co.eurekatic.aicontrol.observaciones;

import java.util.List;
import java.util.Objects;

/**
 * Convierte el {@link ResumenEstructurado} en el texto que se guarda en
 * {@code OBSERVACION} y que imprime el boletin.
 *
 * <p>Texto plano, sin markdown: lo muestra un campo de texto de Jasper y un
 * textarea del front, y ninguno de los dos interpreta asteriscos.
 */
public final class ResumenRenderer {

    private ResumenRenderer() {}

    public static String render(ResumenEstructurado r) {
        StringBuilder sb = new StringBuilder();
        parrafo(sb, r.introduccion());
        if (r.dimensiones() != null) {
            for (ResumenEstructurado.Dimension d : r.dimensiones()) {
                if (d == null || blank(d.descripcion())) continue;
                parrafo(sb, blank(d.nombre())
                        ? d.descripcion().trim()
                        : "Dimensión " + d.nombre().trim() + ": " + d.descripcion().trim());
            }
        }
        lista(sb, "Fortalezas", r.fortalezas());
        lista(sb, "Aspectos por fortalecer", r.aspectosPorFortalecer());
        lista(sb, "Recomendaciones para el hogar", r.recomendaciones());
        parrafo(sb, r.sintesis());
        return sb.toString().trim();
    }

    private static void parrafo(StringBuilder sb, String texto) {
        if (blank(texto)) return;
        if (!sb.isEmpty()) sb.append("\n\n");
        sb.append(texto.trim());
    }

    private static void lista(StringBuilder sb, String titulo, List<String> items) {
        if (items == null) return;
        List<String> limpios = items.stream().filter(Objects::nonNull).map(String::trim)
                .filter(s -> !s.isEmpty()).map(ResumenRenderer::sinPuntoFinal).toList();
        if (limpios.isEmpty()) return;
        parrafo(sb, titulo + ": " + String.join("; ", limpios) + ".");
    }

    private static String sinPuntoFinal(String s) {
        return s.endsWith(".") ? s.substring(0, s.length() - 1) : s;
    }

    private static boolean blank(String s) {
        return s == null || s.isBlank();
    }
}
