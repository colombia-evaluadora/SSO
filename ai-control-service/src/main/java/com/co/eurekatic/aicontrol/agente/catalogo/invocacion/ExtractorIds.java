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

    public static Set<String> extraer(List<Map<String, Object>> filas) {
        Set<String> ids = new LinkedHashSet<>();
        for (Map<String, Object> fila : filas) {
            for (Map.Entry<String, Object> celda : fila.entrySet()) {
                if (ids.size() >= MAX_POR_RESULTADO) {
                    return Set.copyOf(ids);
                }
                if (COLUMNA_ID.matcher(celda.getKey()).matches()) {
                    String id = textoDe(celda.getValue());
                    if (id != null) {
                        ids.add(id);
                    }
                }
            }
        }
        return Set.copyOf(ids);
    }

    /**
     * Forma de texto de un valor que puede ser un id. Un entero llega como {@code 12} aunque
     * el JSON lo trajera como {@code 12.0}; un valor no entero o vacio no es un id: devuelve null.
     */
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
