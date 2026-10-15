package com.co.eurekatic.scheduler.accion;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.convert.DurationStyle;

/** Lectura tipada de los {@code parametros} libres de una tarea. */
public final class Parametros {

    private final String tareaId;
    private final Map<String, Object> valores;

    public Parametros(String tareaId, Map<String, Object> valores) {
        this.tareaId = tareaId;
        this.valores = valores == null ? Map.of() : valores;
    }

    public String requerido(String clave) {
        String valor = texto(clave, null);
        if (valor == null || valor.isBlank()) {
            throw new IllegalArgumentException(
                    "Tarea '%s': falta el parametro '%s'".formatted(tareaId, clave));
        }
        return valor;
    }

    public String texto(String clave, String porDefecto) {
        Object valor = valores.get(clave);
        return valor == null ? porDefecto : valor.toString();
    }

    public Duration duracion(String clave, Duration porDefecto) {
        String valor = texto(clave, null);
        return valor == null ? porDefecto : DurationStyle.detectAndParse(valor);
    }

    /**
     * Sub-mapa de texto. El binder de Spring entrega un mapa anidado de YAML
     * como {@code Map}; un valor escalar en esa clave es un error de
     * configuracion.
     */
    public Map<String, String> mapa(String clave) {
        Object valor = valores.get(clave);
        if (valor == null) {
            return Map.of();
        }
        if (!(valor instanceof Map<?, ?> crudo)) {
            throw new IllegalArgumentException(
                    "Tarea '%s': '%s' debe ser un mapa".formatted(tareaId, clave));
        }
        Map<String, String> resultado = new LinkedHashMap<>();
        crudo.forEach((k, v) -> resultado.put(k.toString(), v == null ? null : v.toString()));
        return resultado;
    }
}
