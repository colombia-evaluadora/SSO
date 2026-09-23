package com.co.eurekatic.aicontrol.observaciones;

import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.util.regex.Pattern;

/**
 * El contrato de salida con el modelo: la instruccion de formato que se le
 * manda y el parseo tolerante de lo que devuelve.
 *
 * <p>No se usa la instruccion de {@code BeanOutputConverter} porque manda el
 * JSON Schema crudo, y los modelos pequenos a veces lo copian: devuelven
 * {@code {"$schema":..., "properties": {<los datos>}}}. Se vio con Nemotron
 * 3.5 Lightning en 1 de cada 4 llamadas. Un ejemplo con la forma exacta se
 * copia bien, y aun asi el parseo desenvuelve {@code properties} y quita
 * cercas de markdown por si el modelo reincide.
 */
final class SalidaModelo {

    static final String FORMATO = """
            Responde UNICAMENTE con un objeto JSON valido (RFC 8259), sin texto antes ni despues \
            y sin bloques de codigo markdown. Usa exactamente estas claves:
            {
              "introduccion": "2 o 3 oraciones con la valoracion general del proceso",
              "dimensiones": [
                {"nombre": "Comunicativa", "descripcion": "descripcion consolidada de los avances en esa dimension"}
              ],
              "fortalezas": ["frase breve"],
              "aspectosPorFortalecer": ["frase breve redactada en positivo"],
              "recomendaciones": ["recomendacion concreta para el hogar"],
              "sintesis": "oracion de cierre"
            }
            Incluye en "dimensiones" solo las que tengan evidencia. Las listas pueden quedar vacias ([]) \
            si no hay informacion. No devuelvas un JSON Schema.""";

    private static final Pattern CERCA_INICIO = Pattern.compile("^```[a-zA-Z]*\\s*");

    private static final JsonMapper JSON = JsonMapper.builder()
            .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .build();

    private SalidaModelo() {}

    /**
     * @throws IllegalArgumentException si no hay un objeto JSON con la forma
     *         esperada; el llamador lo trata como respuesta no valida y reintenta
     */
    static ResumenEstructurado parsear(String crudo) {
        if (crudo == null || crudo.isBlank()) {
            throw new IllegalArgumentException("respuesta vacia");
        }
        String t = crudo.strip();
        if (t.startsWith("```")) {
            t = CERCA_INICIO.matcher(t).replaceFirst("");
            int fin = t.lastIndexOf("```");
            if (fin >= 0) t = t.substring(0, fin);
        }
        int desde = t.indexOf('{');
        int hasta = t.lastIndexOf('}');
        if (desde < 0 || hasta < desde) {
            throw new IllegalArgumentException("sin objeto JSON");
        }
        JsonNode nodo = JSON.readTree(t.substring(desde, hasta + 1));
        if (!tieneClaves(nodo) && nodo.path("properties").isObject()) {
            nodo = nodo.get("properties");
        }
        if (!tieneClaves(nodo)) {
            throw new IllegalArgumentException("JSON sin las claves esperadas");
        }
        return JSON.treeToValue(nodo, ResumenEstructurado.class);
    }

    private static boolean tieneClaves(JsonNode n) {
        return n.has("introduccion") || n.has("dimensiones") || n.has("sintesis");
    }
}
