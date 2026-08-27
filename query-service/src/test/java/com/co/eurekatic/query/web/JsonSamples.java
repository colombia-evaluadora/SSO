package com.co.eurekatic.query.web;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

import java.util.Map;

/**
 * Helpers para construir árboles JSON en tests sin arrastrar
 * el contexto de Spring. Las funciones aceptan:
 *
 * <ul>
 *   <li>{@code obj(Map.of("a", node1, "b", node2))} para
 *       objetos (cualquier número de pares).</li>
 *   <li>{@code arr(node1, node2, ...)} o
 *       {@code arr(Map.of("a", node1, ...))} para arrays.</li>
 *   <li>{@code num(long)}, {@code str(String)}, {@code nul()},
 *       {@code bool(boolean)} para valores escalares.</li>
 * </ul>
 *
 * <p>El "null como valor" se modela con {@link JsonNode} igual
 * a {@code null} (no con un wrapper), para que el caller pueda
 * distinguir "ausente" de "null" mirando la presencia de la
 * entrada en el Map / varargs.
 */
final class JsonSamples {

    private static final JsonNodeFactory F = JsonNodeFactory.instance;
    private JsonSamples() {}

    static JsonNode obj(Map<String, JsonNode> fields) {
        ObjectNode o = F.objectNode();
        fields.forEach((k, v) -> {
            if (v == null) o.putNull(k);
            else o.set(k, v);
        });
        return o;
    }

    /** Construye un objeto con un solo campo bajo {@code rootKey}. */
    static JsonNode objRoot(String rootKey, JsonNode value) {
        ObjectNode o = F.objectNode();
        if (value == null) o.putNull(rootKey);
        else o.set(rootKey, value);
        return o;
    }

    static JsonNode arr(JsonNode... values) {
        ArrayNode a = F.arrayNode();
        for (JsonNode v : values) {
            if (v == null) a.addNull();
            else a.add(v);
        }
        return a;
    }

    static JsonNode num(long v)     { return F.numberNode(v); }
    static JsonNode num(double v)   { return F.numberNode(v); }
    static JsonNode str(String v)   { return F.stringNode(v); }
    static JsonNode bool(boolean v) { return F.booleanNode(v); }
    /** Sentinel: devuelve null, no un NullNode. */
    static JsonNode nul()           { return null; }
    /** Sentinel: NullNode real (cuando se quiere serializar null). */
    static JsonNode nullNode()      { return F.nullNode(); }
}
