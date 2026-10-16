package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Quita de las filas las columnas sensibles antes de que salgan hacia el modelo: datos de
 * menores (documentos, correos, telefonos, direcciones...). Pura.
 *
 * <p>Coincidencia por fragmento, sin distinguir mayusculas: {@code numero_documento} cae por
 * {@code documento}. Los ids nunca se quitan, aunque su nombre contenga un fragmento
 * ({@code fk_tdocumento} es un pk de catalogo): el modelo los necesita para resolver. Los
 * nombres se conservan. Los valores anidados se revisan con la misma regla.
 */
public final class FiltroColumnasSensibles {

    private final List<String> fragmentos;

    public FiltroColumnasSensibles(List<String> columnasSensibles) {
        this.fragmentos = columnasSensibles.stream()
                .map(f -> f.trim().toLowerCase(Locale.ROOT))
                .filter(f -> !f.isEmpty())
                .toList();
    }

    public List<Map<String, Object>> aplicar(List<Map<String, Object>> filas) {
        List<Map<String, Object>> limpias = new ArrayList<>(filas.size());
        for (Map<String, Object> fila : filas) {
            limpias.add(limpiarMapa(fila));
        }
        return List.copyOf(limpias);
    }

    /** Si una columna se oculta al modelo. */
    public boolean esSensible(String columna) {
        if (ExtractorIds.esColumnaId(columna)) {
            return false;
        }
        String minusculas = columna.toLowerCase(Locale.ROOT);
        return fragmentos.stream().anyMatch(minusculas::contains);
    }

    private Map<String, Object> limpiarMapa(Map<String, Object> mapa) {
        Map<String, Object> resultado = new LinkedHashMap<>();
        for (Map.Entry<String, Object> celda : mapa.entrySet()) {
            if (!esSensible(celda.getKey())) {
                resultado.put(celda.getKey(), limpiarValor(celda.getValue()));
            }
        }
        return resultado;
    }

    private Object limpiarValor(Object valor) {
        if (valor instanceof Map<?, ?> mapa) {
            @SuppressWarnings("unchecked")
            Map<String, Object> anidado = (Map<String, Object>) mapa;
            return limpiarMapa(anidado);
        }
        if (valor instanceof List<?> lista) {
            return lista.stream().map(this::limpiarValor).toList();
        }
        return valor;
    }
}
