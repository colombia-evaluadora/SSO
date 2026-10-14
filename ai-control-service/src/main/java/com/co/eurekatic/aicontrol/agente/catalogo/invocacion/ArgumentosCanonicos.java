package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/**
 * Argumentos ya validados, con claves canonicas ({@code PARAM.ID}, {@code QUERY.GRUPO},
 * {@code BODY.PERSON.EMAIL}). Desde aqui cada seccion sale a su sitio en la peticion:
 * {@code PARAM} al path, {@code QUERY} a la query string y {@code BODY} al cuerpo anidado.
 *
 * @param planos valor de cada clave canonica validada; ningun valor es nulo
 */
public record ArgumentosCanonicos(Map<String, Object> planos) {

    private static final String PARAM = "PARAM.";
    private static final String QUERY = "QUERY.";
    private static final String BODY = "BODY.";

    public ArgumentosCanonicos {
        Objects.requireNonNull(planos, "planos");
        for (Map.Entry<String, Object> e : planos.entrySet()) {
            Objects.requireNonNull(e.getValue(), "valor nulo para " + e.getKey());
            if (!(e.getKey().startsWith(PARAM) || e.getKey().startsWith(QUERY) || e.getKey().startsWith(BODY))) {
                throw new IllegalArgumentException("clave canonica sin seccion: " + e.getKey());
            }
        }
        planos = Collections.unmodifiableMap(new LinkedHashMap<>(planos));
    }

    /** Valores de {@code PARAM.*}, con la clave sin el prefijo: {@code ID}. */
    public Map<String, Object> pathParams() {
        return seccion(PARAM);
    }

    /** Valores de {@code QUERY.*}, con la clave sin el prefijo. */
    public Map<String, Object> query() {
        return seccion(QUERY);
    }

    /** Valores de {@code BODY.*} anidados por punto: {@code BODY.PERSON.EMAIL} es {@code {PERSON:{EMAIL:...}}}. */
    public Map<String, Object> body() {
        Map<String, Object> raiz = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : planos.entrySet()) {
            if (!e.getKey().startsWith(BODY)) {
                continue;
            }
            String[] segmentos = e.getKey().substring(BODY.length()).split("\\.");
            Map<String, Object> nivel = raiz;
            for (int i = 0; i < segmentos.length - 1; i++) {
                Object existente = nivel.computeIfAbsent(segmentos[i], k -> new LinkedHashMap<String, Object>());
                if (!(existente instanceof Map<?, ?>)) {
                    throw new IllegalStateException("conflicto de claves BODY en " + e.getKey());
                }
                @SuppressWarnings("unchecked")
                Map<String, Object> hijo = (Map<String, Object>) existente;
                nivel = hijo;
            }
            nivel.put(segmentos[segmentos.length - 1], e.getValue());
        }
        return raiz;
    }

    private Map<String, Object> seccion(String prefijo) {
        Map<String, Object> resultado = new LinkedHashMap<>();
        planos.forEach((clave, valor) -> {
            if (clave.startsWith(prefijo)) {
                resultado.put(clave.substring(prefijo.length()), valor);
            }
        });
        return Collections.unmodifiableMap(resultado);
    }
}
