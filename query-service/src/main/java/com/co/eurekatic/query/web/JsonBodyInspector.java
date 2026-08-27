package com.co.eurekatic.query.web;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.BigIntegerNode;
import tools.jackson.databind.node.DecimalNode;
import tools.jackson.databind.node.DoubleNode;
import tools.jackson.databind.node.FloatNode;
import tools.jackson.databind.node.IntNode;
import tools.jackson.databind.node.LongNode;
import tools.jackson.databind.node.NumericNode;
import tools.jackson.databind.node.ObjectNode;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * V60 — Inspección tipada del body de la query.
 *
 * <p>El log de producción que motivó este refactor mostraba
 * cuerpos que {@code @RequestBody Map<String,Object>}
 * deserializaba con tipos distintos a los que el cliente había
 * enviado — un {@code BigInteger} que Jackson entregó como
 * {@code Integer} cuando el valor cabía en 32 bits, un
 * {@code null} que se convirtió mágicamente a {@code "null"}
 * String, etc. La causa raíz es que la firma
 * {@code Map<String,Object>} pide a Jackson que adivine el tipo
 * Java de cada valor y pierda información cuando esa elección
 * no encaja con el declarado en {@code paramTypes}.
 *
 * <p>Este inspector trabaja sobre el {@code JsonNode} antes de
 * la conversión a {@code Map}, capturando el tipo concreto del
 * árbol JSON. La capa de bind (
 * {@link com.co.eurekatic.common.query.ParamBinder}) lo consume
 * en una fase posterior; aquí sólo validamos forma y reportamos
 * anomalías con el nombre de la key que falla, así el operador
 * sabe qué campo del body corregir.
 *
 * <p>Lo que NO hace este inspector:
 * <ul>
 *   <li>No convierte a un tipo Java concreto (eso es decisión
 *       del catálogo via {@code paramTypes}).</li>
 *   <li>No acepta tipos del body que el catálogo no espera —
 *       eso lo hace la guardia runtime del {@code QueryService}.</li>
 *   <li>No muta el árbol: la inspección es de sólo lectura. La
 *       conversión a {@code Map<String,Object>} ocurre después,
 *       a través del método Jackson estándar.</li>
 * </ul>
 */
public final class JsonBodyInspector {

    private JsonBodyInspector() {}

    /**
     * Categoría del tipo JSON. Se usa para producir mensajes de
     * error y alimentar la métrica
     * {@code query.body.inspect}.
     */
    public enum JsonKind {
        NULL, BOOLEAN, INTEGER, FLOAT, STRING, ARRAY, OBJECT
    }

    /**
     * Vista tipada inmutable de un valor del body. No es la
     * conversión a Java — el Java tipo se decide en el binder
     * mirando {@code paramTypes}. La vista aquí es para
     * inspección y validación temprana.
     */
    public record TypedValue(JsonKind kind, boolean isNull, int depth) {
        public static final TypedValue NULL = new TypedValue(JsonKind.NULL, true, 0);

        public static TypedValue of(JsonKind k) {
            return new TypedValue(k, false, 0);
        }

        public boolean isScalar() {
            return kind == JsonKind.NULL
                    || kind == JsonKind.BOOLEAN
                    || kind == JsonKind.INTEGER
                    || kind == JsonKind.FLOAT
                    || kind == JsonKind.STRING;
        }

        public boolean isContainer() {
            return kind == JsonKind.ARRAY || kind == JsonKind.OBJECT;
        }
    }

    /**
     * Resultado de la inspección: el kind de la raíz y, si es
     * un objeto, el kind de cada clave top-level. Cualquier
     * violación de forma se acumula en {@code violations} — el
     * método {@link #validate} la convierte en un
     * {@code ResponseStatusException} 400 en el caller.
     */
    public record InspectionReport(
            JsonKind rootKind,
            Map<String, TypedValue> topLevelTypes,
            java.util.List<String> violations) {

        public boolean isClean() {
            return violations.isEmpty();
        }

        public static InspectionReport empty() {
            return new InspectionReport(JsonKind.NULL, Map.of(), new java.util.ArrayList<>());
        }
    }

    /**
     * Inspecciona el nodo pasado y reporta violaciones de forma.
     * El caller es responsable de extraer el sub-árbol
     * apropiado de su body antes de llamar (p. ej.
     * {@code params} o {@code columns}).
     *
     * @param node el sub-árbol a inspeccionar
     * @param rootPath ruta lógica que se antepone a cada
     *                violation, para que el mensaje sea útil
     *                sin importar de dónde sacó el caller el
     *                nodo (típicamente {@code "params"} o
     *                {@code "columns"}).
     */
    public static InspectionReport inspect(JsonNode node, String rootPath) {
        java.util.ArrayList<String> violations = new java.util.ArrayList<>();
        InspectionReport rep = scanObject(rootPath, node, violations, /* depth */ 1);
        return rep;
    }

    private static InspectionReport scanObject(String key, JsonNode node,
                                               java.util.List<String> violations,
                                               int depth) {
        if (node == null || node.isNull()) {
            violations.add("El campo '" + key + "' llegó como null; se esperaba un objeto");
            return new InspectionReport(JsonKind.NULL, Map.of(), violations);
        }
        if (!node.isObject()) {
            violations.add("El campo '" + key + "' debe ser un objeto, llegó "
                    + describe(node) + ". Revisa que la raíz sea {...} y no [...].");
            return new InspectionReport(kindOf(node), Map.of(), violations);
        }
        Map<String, TypedValue> types = new LinkedHashMap<>();
        ObjectNode obj = (ObjectNode) node;
        int count = obj.size();
        if (count > MAX_FIELDS_PER_OBJECT) {
            violations.add("El objeto '" + key + "' tiene " + count
                    + " campos (máximo recomendado " + MAX_FIELDS_PER_OBJECT
                    + "). Probable error en el cliente — el body parece estar mal armado.");
            return new InspectionReport(JsonKind.OBJECT, types, violations);
        }
        obj.propertyStream().forEach(entry -> {
            String name = entry.getKey();
            JsonNode child = entry.getValue();
            TypedValue tv = kindOfTypedValue(child, depth + 1);
            types.put(name, tv);
            if (depth > MAX_DEPTH) {
                violations.add("Anidamiento demasiado profundo bajo '" + key
                        + "." + name + "' (profundidad=" + depth + ", máximo="
                        + MAX_DEPTH + ")");
                return;
            }
            if (child.isArray()) {
                checkArrayElementKinds(key + "." + name, child, violations);
                // Inspecciona también los elementos si son objetos.
                for (int i = 0; i < ((ArrayNode) child).size(); i++) {
                    JsonNode elem = ((ArrayNode) child).get(i);
                    if (elem != null && elem.isObject()) {
                        scanObject(key + "." + name + "[" + i + "]",
                                elem, violations, depth + 1);
                    }
                }
            } else if (child.isObject()) {
                scanObject(key + "." + name, child, violations, depth + 1);
            }
        });
        return new InspectionReport(JsonKind.OBJECT, types, violations);
    }

    /**
     * Verifica que todos los elementos de un array tengan el
     * mismo "kind" — un {@code [1, "2", 3.5]} mezcla INTEGER /
     * STRING / FLOAT y es síntoma de un cliente que no está
     * tipando el JSON. Lo dejamos pasar (porque la guardia del
     * {@code QueryService} por tipo declarado lo rechazará), pero
     * registramos el detalle en las violations para que el log
     * del servidor quede diagnóstico.
     */
    private static void checkArrayElementKinds(String path, JsonNode array,
                                               java.util.List<String> violations) {
        if (!array.isArray()) return;
        ArrayNode arr = (ArrayNode) array;
        if (arr.size() > MAX_ARRAY_LENGTH) {
            violations.add("El array '" + path + "' tiene " + arr.size()
                    + " elementos (máximo recomendado " + MAX_ARRAY_LENGTH
                    + "). Body demasiado grande — revisa si el cliente está enviándolo duplicado.");
            return;
        }
        JsonKind firstScalar = null;
        for (int i = 0; i < arr.size(); i++) {
            JsonNode elem = arr.get(i);
            if (elem == null || elem.isNull()) continue;
            if (elem.isValueNode()) {
                JsonKind k = kindOf(elem);
                if (firstScalar == null) firstScalar = k;
                else if (firstScalar != k) {
                    violations.add("El array '" + path + "' mezcla tipos: primer="
                            + firstScalar + " elem[" + i + "]=" + k
                            + ". El catálogo exige un único tipo declarado en paramTypes.");
                }
            }
        }
    }

    private static TypedValue kindOfTypedValue(JsonNode node, int depth) {
        if (node == null || node.isNull()) return TypedValue.NULL;
        return new TypedValue(kindOf(node), false, depth);
    }

    /**
     * Kind JSON del nodo, agnóstico del binding Java. Aquí no se
     * decide entre Integer y Long — el catálogo decide después.
     */
    public static JsonKind kindOf(JsonNode node) {
        if (node == null || node.isNull()) return JsonKind.NULL;
        if (node.isBoolean()) return JsonKind.BOOLEAN;
        if (node.isString()) return JsonKind.STRING;
        if (node.isInt()) return JsonKind.INTEGER;
        if (node.isBigInteger()) return JsonKind.INTEGER;
        if (node.isLong()) return JsonKind.INTEGER;
        if (node.isShort()) return JsonKind.INTEGER;
        if (node.isBigDecimal() || node.isFloat() || node.isDouble()) return JsonKind.FLOAT;
        // NumericNode cubre IntNode / LongNode / BigIntegerNode /
        // DecimalNode / DoubleNode / FloatNode. Si llegamos
        // aquí con un numérico no clasificado arriba, INTEGER
        // o FLOAT según sea integral vs fraccionario.
        if (node instanceof NumericNode) {
            return (node.isFloatingPointNumber() || node.isBigDecimal())
                    ? JsonKind.FLOAT : JsonKind.INTEGER;
        }
        if (node.isArray()) return JsonKind.ARRAY;
        if (node.isObject()) return JsonKind.OBJECT;
        return JsonKind.NULL;
    }

    private static String describe(JsonNode n) {
        if (n == null || n.isNull()) return "null";
        if (n.isArray()) return "array";
        if (n.isObject()) return "objeto";
        if (n.isBoolean()) return "booleano";
        if (n.isString()) return "cadena";
        if (n instanceof DoubleNode || n instanceof FloatNode
                || n instanceof DecimalNode) return "número fraccionario";
        if (n instanceof IntNode || n instanceof LongNode
                || n instanceof BigIntegerNode) return "número entero";
        return "tipo JSON desconocido";
    }

    /**
     * Tope defensivo: un array con 10k elementos es síntoma de
     * un cliente que envía el resultado de un SELECT como
     * parámetro (anti-patrón conocido). Por debajo de este
     * umbral dejamos que el catálogo decida.
     */
    static final int MAX_ARRAY_LENGTH = 5000;

    /**
     * Tope defensivo de profundidad para el body. Un objeto a
     * 5+ niveles de profundidad es raro y suele ser un bug del
     * cliente.
     */
    static final int MAX_DEPTH = 4;

    /**
     * Tope defensivo de campos top-level por objeto. 100 campos
     * en un solo objeto es síntoma del mismo anti-patrón.
     */
    static final int MAX_FIELDS_PER_OBJECT = 100;
}
