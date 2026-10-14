package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;

/**
 * El nombre legible de cada id que deja un resultado: {@code grupo=990201} es "A", {@code lista_valor=370} es
 * "Ponderar". Un id se nombra por su columna gemela ({@code grupo_id} y {@code grupo_etiqueta}, {@code fk_tasignatura}
 * y {@code asignatura}, {@code fk_tlv_estado} y {@code estado_nombre}) o, el primero de la fila, por el nombre de la
 * fila ({@code titulo}, {@code nombre}...). La clave es {@code entidad=id} y tambien el id solo (lo usa un
 * {@code PARAM.ID}, que no dice su entidad). Pura.
 */
public final class EtiquetasIds {

    /** Columnas que nombran la fila entera, por preferencia. */
    private static final List<String> NOMBRES_DE_FILA =
            List.of("titulo", "nombre_completo", "nombre", "name", "etiqueta", "estudiante", "valor");
    static final int MAX_LARGO = 80;

    private EtiquetasIds() {
    }

    public static Map<String, String> extraer(List<Map<String, Object>> filas) {
        Map<String, String> etiquetas = new LinkedHashMap<>();
        filas.forEach(fila -> recorrer(fila, etiquetas));
        return etiquetas;
    }

    private static void recorrer(Object valor, Map<String, String> etiquetas) {
        switch (valor) {
            case Map<?, ?> mapa -> {
                if (etiquetas.size() < ExtractorIds.MAX_POR_RESULTADO * 2) {
                    deFila(mapa, etiquetas);
                }
                mapa.values().forEach(celda -> recorrer(celda, etiquetas));
            }
            case List<?> lista -> lista.forEach(elemento -> recorrer(elemento, etiquetas));
            case null, default -> {
            }
        }
    }

    private static void deFila(Map<?, ?> fila, Map<String, String> etiquetas) {
        boolean principal = true;
        for (Map.Entry<?, ?> celda : fila.entrySet()) {
            String columna = String.valueOf(celda.getKey());
            if (!ExtractorIds.esColumnaId(columna)) {
                continue;
            }
            String id = ExtractorIds.textoDe(celda.getValue());
            if (id == null) {
                continue;
            }
            Optional<String> etiqueta = gemela(fila, columna);
            if (etiqueta.isEmpty() && principal) {
                etiqueta = NOMBRES_DE_FILA.stream().map(n -> texto(fila.get(n))).flatMap(Optional::stream).findFirst();
            }
            principal = false;
            etiqueta.ifPresent(e -> {
                ExtractorIds.entidadDeColumna(columna).ifPresent(ent -> etiquetas.putIfAbsent(ent + "=" + id, e));
                etiquetas.putIfAbsent(id, e);
            });
        }
    }

    /** {@code grupo_id} se nombra en {@code grupo}, {@code grupo_etiqueta} o {@code grupo_nombre}. */
    private static Optional<String> gemela(Map<?, ?> fila, String columna) {
        String raiz = raiz(columna.toLowerCase(Locale.ROOT));
        if (raiz.isEmpty()) {
            return Optional.empty();
        }
        return List.of(raiz, raiz + "_etiqueta", raiz + "_nombre", "nombre_" + raiz).stream()
                .filter(n -> !n.equals(columna))
                .map(n -> texto(fila.get(n)))
                .flatMap(Optional::stream)
                .findFirst();
    }

    private static String raiz(String columna) {
        for (String prefijo : new String[] {"fk_tlv_", "pk_t", "fk_t", "pk_", "fk_"}) {
            if (columna.startsWith(prefijo)) {
                return columna.substring(prefijo.length());
            }
        }
        return columna.endsWith("_id") ? columna.substring(0, columna.length() - 3) : "";
    }

    private static Optional<String> texto(Object valor) {
        if (!(valor instanceof String s) || s.isBlank()) {
            return Optional.empty();
        }
        String limpio = s.strip();
        return Optional.of(limpio.length() > MAX_LARGO ? limpio.substring(0, MAX_LARGO) + "…" : limpio);
    }

    /**
     * La etiqueta del valor de un parametro: por su entidad si la nombra (el 370 de un grupo no es el 370 de un
     * catalogo), si no por el id solo.
     */
    public static Optional<String> de(Map<String, String> etiquetas, String clave, Object valor) {
        String id = ExtractorIds.textoDe(valor);
        if (id == null) {
            return Optional.empty();
        }
        String llave = ExtractorIds.entidadDeParametro(clave).map(ent -> ent + "=" + id).orElse(id);
        return Optional.ofNullable(etiquetas.get(llave));
    }
}
