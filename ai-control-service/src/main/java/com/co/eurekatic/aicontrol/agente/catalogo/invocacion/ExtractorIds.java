package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.math.BigDecimal;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Extrae los ids que un resultado deja a la vista del modelo, y los canonicaliza como texto
 * para compararlos despues. Pura.
 */
public final class ExtractorIds {

    /** Columnas que parecen ids: {@code id}, {@code pk_*}, {@code fk_*}, {@code *_id}, {@code idParent}. */
    private static final Pattern COLUMNA_ID = Pattern.compile("(?i)(id|idparent|pk_.+|fk_.+|.+_id)");

    /** Tope de ids que se guardan por resultado: un listado enorme no debe inflar Redis. */
    static final int MAX_POR_RESULTADO = 500;

    private ExtractorIds() {
    }

    /**
     * Tambien dentro de objetos y listas anidados: hay listados paginados que llegan como
     * {@code {"rows":[{"rows":[...], "total_count":...}]}} y los roles o sedes de una fila van en una lista.
     */
    public static Set<String> extraer(List<Map<String, Object>> filas) {
        Set<String> ids = new LinkedHashSet<>();
        filas.forEach(fila -> recorrer(fila, ids));
        return Set.copyOf(ids);
    }

    private static void recorrer(Object valor, Set<String> ids) {
        switch (valor) {
            case Map<?, ?> mapa -> mapa.forEach((clave, celda) -> {
                if (ids.size() >= MAX_POR_RESULTADO) {
                    return;
                }
                String id = esColumnaId(String.valueOf(clave)) ? textoDe(celda) : null;
                if (id != null) {
                    ids.add(id);
                } else {
                    recorrer(celda, ids);
                }
            });
            case List<?> lista -> lista.forEach(elemento -> recorrer(elemento, ids));
            case null, default -> {
            }
        }
    }

    /**
     * Forma de texto de un valor que puede ser un id. Un entero llega como {@code 12} aunque
     * el JSON lo trajera como {@code 12.0}; un valor no entero o vacio no es un id: devuelve null.
     */
    /** Si el nombre de una columna es de identificador. Lo usan la extraccion de ids y el filtro de columnas. */
    public static boolean esColumnaId(String columna) {
        return COLUMNA_ID.matcher(columna).matches();
    }

    public static String textoDe(Object valor) {
        if (valor instanceof Number numero) {
            if (numero instanceof Double d && !Double.isFinite(d)) {
                return null;
            }
            BigDecimal decimal = new BigDecimal(numero.toString());
            return decimal.stripTrailingZeros().scale() > 0 ? null : decimal.toBigInteger().toString();
        }
        if (valor instanceof String texto && !texto.isBlank()) {
            return texto.trim();
        }
        return null;
    }
}
