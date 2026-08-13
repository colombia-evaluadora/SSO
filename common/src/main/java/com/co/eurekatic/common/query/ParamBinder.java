package com.co.eurekatic.common.query;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Time;
import java.sql.Timestamp;
import java.sql.Types;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * V49-bis — construye un {@link MapSqlParameterSource} serializando cada
 * valor a String para que PG haga el cast en SQL (vía {@link SqlRewriter}).
 *
 * <p><b>Por qué serializar a texto en lugar de {@code addValue(k, v, sqlType)}</b>:
 * el camino JDBC obliga al driver a conocer el tipo PG destino. Eso falla con
 * tipos que el driver no maneja nativamente (DOMAIN types del schema
 * {@code academico_test}, funciones PG con firma específica, etc.). El nuevo
 * flujo es:
 * <ol>
 *   <li>El {@link SqlRewriter} inserta {@code cast(:PH as TIPO)} en el SQL.</li>
 *   <li>Este binder pasa el valor como texto plano.</li>
 *   <li>PG aplica el cast en su contexto (donde {@code search_path} sí
 *       resuelve los DOMAIN types).</li>
 * </ol>
 *
 * <p><b>Arrays como texto PG-array</b>: cuando el tipo declarado es
 * {@code TIPO[]} (ej. {@code BIGINT[]}), el valor se serializa al formato
 * PG-array {@code "{1,2,3}"} con quoting correcto por elemento. PG lo
 * parsea via el cast {@code as int8[]}.
 *
 * <p><b>Sub-objetos completos</b>: cuando la key es {@code BODY_RAW.X} y el
 * valor es un {@code Map}, se serializa como JSON literal
 * ({@code {"k":"v"}}). El cast {@code as jsonb} lo acepta.
 *
 * <p><b>Sin tipo declarado</b>: si la key no aparece en {@code paramTypes},
 * el valor se pasa como {@code String.valueOf(val)}. El {@code SqlRewriter}
 * no insertó ningún cast y el bind queda como texto puro — la guardia
 * runtime del {@code QueryService} ya rechazó el caso antes de llegar aquí.
 *
 * <p><b>V60 (validación temprana)</b>: cuando se llama al overload
 * {@link #buildStrict(Map, Map, java.util.List)}, cada (key, valor, tipo)
 * se valida antes de bindear. La intención es cortar los
 * {@code cast(:k as TIPO)} de PG que devolverían un críptico
 * {@code SQLSTATE 22P02} cuando el cliente manda, p.ej., un String
 * donde el catálogo declara BIGINT — Jackson entregó un String
 * cuando lo que se necesitaba era un Long. La validación nombra
 * la key y el tipo esperado, así el operador ve el error sin
 * tener que mirar el log de PG.
 *
 * <p><b>Legacy / backward-compat</b>: el camino
 * {@code QueryService.executeCallable} (CallableStatement con OUT params)
 * sigue usando {@code cs.setObject(k, v, sqlType)} con el map
 * {@link ParamTypes#JDBC_TYPES} — CallableStatement requiere sqlType
 * explícito para OUT, y no entra al SqlRewriter.
 */
public final class ParamBinder {

    private ParamBinder() {}

    public static MapSqlParameterSource build(Map<String, Object> values,
                                              Map<String, String> paramTypes) {
        return buildStrict(values, paramTypes,
                java.util.Map.of() /* no extra declared types */);
    }

    /**
     * Variante estricta: además de serializar, valida que el
     * tipo Java del valor coincida con el declarado para cada
     * placeholder. Si hay mismatch, lanza
     * {@link IllegalArgumentException} con un mensaje que
     * nombra la key, el placeholder del SQL (si se conoce), y
     * el tipo observado vs el esperado.
     *
     * @param extraDeclared map adicional de {key → tipo} que se
     *                      suma a {@code paramTypes} para
     *                      validación. Útil cuando el caller
     *                      ya computó tipos por su cuenta (p.ej.
     *                      desde un JsonNode tree).
     */
    public static MapSqlParameterSource buildStrict(
            Map<String, Object> values,
            Map<String, String> paramTypes,
            Map<String, String> extraDeclared) {
        Map<String, String> types = mergeTypes(paramTypes, extraDeclared);
        MapSqlParameterSource src = new MapSqlParameterSource();
        if (values == null) return src;

        for (Map.Entry<String, Object> e : values.entrySet()) {
            String key = e.getKey();
            Object val = e.getValue();
            String declaredType = types.get(key);
            if (declaredType == null) {
                // V60-bis — el cliente puede haber escrito la
                // key en cualquier caja. Buscamos la
                // representación canónica (MAYÚSCULAS +
                // namespace prefix) contra el catálogo.
                String canonical = canonicalLookupKey(key);
                if (canonical != null) {
                    declaredType = types.get(canonical);
                }
            }

            if (val == null) {
                // null: no se bindea. PG interpreta el placeholder como NULL
                // sólo si el cast lo permite; si no, hay que usar COALESCE en SQL.
                // Saltarse el addValue evita que JDBC mande setObject(k, null)
                // con tipo desconocido.
                continue;
            }

            if (declaredType != null) {
                String problem = validateAgainstDeclared(key, val, declaredType);
                if (problem != null) {
                    throw new IllegalArgumentException(problem);
                }
            }

            String serialized;
            try {
                if (declaredType != null && ParamTypes.ARRAY_TYPES.contains(declaredType)) {
                    serialized = toPgArray(val);
                } else if (key.startsWith(ParamNamespace.BODY_RAW + ".") && val instanceof Map) {
                    serialized = toJsonLiteral((Map<?, ?>) val);
                } else {
                    serialized = stringify(val);
                }
            } catch (IllegalArgumentException ex) {
                throw new IllegalArgumentException(
                        "No se puede serializar el parámetro '" + key
                        + "' al tipo declarado " + declaredType + ": "
                        + ex.getMessage());
            }
            src.addValue(key, serialized);
            // V60-bis — publicamos también varias variantes
            // canonicales para que un SQL con placeholder
            // UPPERCASA O minúsculas, con namespace O sin él,
            // encuentre el valor aunque el cliente haya
            // enviado la key en una caja arbitraria.
            //
            // Tres aliases:
            //  - upper: mayúsculas (sin namespace) — para
            //    SQL legacy con :id en mayúsculas.
            //  - canonical: namespace-prefixado en MAYÚSCULAS
            //    (BODY.X para body-scope) — para SQL con
            //    placeholder moderno :BODY.X.
            //  - lower: minúsculas (sin namespace) — para
            //    SQL legacy con :id en minúsculas.
            //
            // Spring NamedParameterUtils es case-sensitive
            // sobre los placeholders del SQL, así que con
            // tres aliases el bind funciona en cualquier
            // combinación de cajas y namespaces.
            String upper = key.toUpperCase(java.util.Locale.ROOT);
            String lower = key.toLowerCase(java.util.Locale.ROOT);
            String canonical = canonicalLookupKey(key);
            if (canonical != null && !canonical.equals(key)) {
                src.addValue(canonical, serialized);
            }
            if (!upper.equals(key) && !upper.equals(canonical)) {
                src.addValue(upper, serialized);
            }
            if (!lower.equals(key) && !lower.equals(canonical) && !lower.equals(upper)) {
                src.addValue(lower, serialized);
            }
        }
        return src;
    }

    /**
     * Genera las variantes canónicas de {@code key} contra las
     * que un catálogo puede haber declarado el tipo. Devuelve
     * la primera que NO esté vacía — el binder usa esa para
     * el lookup en {@code paramTypes}.
     *
     * <p>Por ejemplo, para la key {@code "size"} del
     * cliente: prueba {@code "size"} (literal), {@code "SIZE"}
     * (upper), {@code "QUERY.SIZE"} (con prefijo derivado
     * del namespace QUERY si la key viene suelta) — la
     * primera que el catálogo tenga declarada gana.
     */
    public static String canonicalLookupKey(String key) {
        if (key == null || key.isEmpty()) return null;
        // La forma canónica Body-namespace-prefixed es la
        // que casi siempre declara el catálogo. Si el
        // cliente ya escribió el prefijo, canonicalKeyFor
        // no lo duplica.
        for (String ns : new String[]{
                ParamNamespace.BODY, ParamNamespace.BODY_RAW,
                ParamNamespace.QUERY, ParamNamespace.PARAM,
                ParamNamespace.CONTEXT}) {
            String canonical = ParamNamespace.canonicalKeyFor(key, ns);
            if (canonical != null && !canonical.equals(key)) {
                return canonical;
            }
        }
        return null;
    }

    private static Map<String, String> mergeTypes(Map<String, String> base,
                                                   Map<String, String> extra) {
        if (base == null && extra == null) return Map.of();
        if (base == null) return extra;
        if (extra == null) return base;
        java.util.LinkedHashMap<String, String> merged = new java.util.LinkedHashMap<>(base);
        merged.putAll(extra);
        return merged;
    }

    /**
     * Comprueba que el tipo Java del valor sea compatible con
     * el declarado en {@code paramTypes}. Devuelve
     * {@code null} si está bien, o un mensaje listo para el
     * 400 del llamante.
     *
     * <p>La regla es deliberadamente laxa: aceptamos cualquier
     * número donde se declaró un número (Integer, Long,
     * BigInteger, BigDecimal, etc.) y rechazamos mezclas
     * absurdas (String para BIGINT, Boolean para TIMESTAMP).
     * La coerción fina la hace PG vía el cast insertado por
     * {@code SqlRewriter} — la guardia sólo corta los casos
     * donde PG daría un mensaje críptico que no ayuda al
     * operador.
     */
    static String validateAgainstDeclared(String key, Object val, String declared) {
        if (val == null || declared == null) return null;
        String up = declared.trim().toUpperCase(Locale.ROOT);

        // Arrays
        if (ParamTypes.ARRAY_TYPES.contains(up)) {
            if (!(val instanceof List<?>) && !val.getClass().isArray()) {
                return "El parámetro '" + key + "' se declaró como " + up
                        + " (array) pero el cliente envió "
                        + val.getClass().getSimpleName()
                        + ". Verifica que el JSON tenga un [...] y no un escalar.";
            }
            if (val instanceof List<?> list) {
                int wrong = -1;
                Class<?> elementExpected = arrayElementType(up);
                if (elementExpected != null) {
                    for (int i = 0; i < list.size(); i++) {
                        Object el = list.get(i);
                        if (el == null) continue;
                        if (!isCompatibleWith(el, elementExpected)) {
                            wrong = i;
                            break;
                        }
                    }
                }
                if (wrong >= 0) {
                    Object el = list.get(wrong);
                    return "El array '" + key + "' se declaró como " + up
                            + " pero el elemento [" + wrong + "] es "
                            + (el == null ? "null" : el.getClass().getSimpleName())
                            + " (esperado " + elementExpected.getSimpleName()
                            + "). Mezclar tipos en el array produce errores crípticos de PG; "
                            + "el cliente debe enviar todos los elementos del mismo tipo.";
                }
            }
            return null;
        }

        // JSONB / JSON — sólo aceptamos Map o String (un
        // JSON literal que ya viene como String del cliente es
        // legal; no lo rechazamos).
        if ("JSONB".equals(up) || "JSON".equals(up)) {
            if (val instanceof Map || val instanceof String) return null;
            return "El parámetro '" + key + "' se declaró como " + up
                    + " pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". Para JSONB/JSONB usa BODY_RAW.X con un sub-objeto completo.";
        }

        // Booleano
        if ("BOOLEAN".equals(up)) {
            if (!(val instanceof Boolean)) {
                return "El parámetro '" + key + "' se declaró como BOOLEAN pero el cliente envió "
                        + val.getClass().getSimpleName()
                        + ". Verifica que el JSON use true/false y no 0/1 o \"S\"/\"N\".";
            }
            return null;
        }

        // Numéricos enteros
        if (ParamTypes.INTEGER_TYPES.contains(up)) {
            if (isIntegerFamily(val)) return null;
            if (val instanceof String s) {
                try {
                    Long.parseLong(s);
                    return null;
                } catch (NumberFormatException ignored) {
                    // cae al mensaje de abajo
                }
            }
            return "El parámetro '" + key + "' se declaró como " + up
                    + " (entero) pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". Verifica que el campo lleve un número sin decimales.";
        }

        // Numéricos con decimales
        if (ParamTypes.DECIMAL_TYPES.contains(up)) {
            if (isDecimalFamily(val)) return null;
            if (val instanceof String s) {
                try {
                    new BigDecimal(s);
                    return null;
                } catch (NumberFormatException ignored) {
                    // cae al mensaje
                }
            }
            return "El parámetro '" + key + "' se declaró como " + up
                    + " (numérico con decimales) pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". Verifica que el campo lleve un número (entero o decimal).";
        }

        // Texto y CHAR(1) — aceptamos cualquier cosa; PG hará
        // el chequeo fino (truncamiento, codificación).
        if (ParamTypes.STRING_TYPES.contains(up)) {
            return null;
        }

        // UUID — sólo aceptamos String (un UUID textual) o java.util.UUID.
        if ("UUID".equals(up)) {
            if (val instanceof String || val instanceof java.util.UUID) return null;
            return "El parámetro '" + key + "' se declaró como UUID pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". UUID debe ir como cadena con formato estándar.";
        }

        // DATE / TIME / TIMESTAMP / TIMESTAMPTZ — aceptamos
        // String (formato ISO-8601) o los java.sql.* / java.time.*
        // que Jackson entregue por reflexión. Para esta v60 no
        // distinguimos java.time.Instant de java.util.Date — PG
        // recibe texto y aplica el cast.
        if (ParamTypes.TEMPORAL_TYPES.contains(up)) {
            if (val instanceof String
                    || val instanceof java.sql.Date
                    || val instanceof Time
                    || val instanceof Timestamp
                    || val instanceof java.time.temporal.Temporal) {
                return null;
            }
            return "El parámetro '" + key + "' se declaró como " + up
                    + " pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". Usa una cadena ISO-8601 o un tipo fecha/hora.";
        }

        // DOMAIN types — el binder serializa a texto; PG
        // valida el CHECK constraint. La guardia aquí no
        // puede añadir información útil, así que dejamos
        // pasar.
        if (ParamTypes.DOMAIN_TYPES.contains(up)) {
            return null;
        }

        // Tipo desconocido declarado — defensivo, no rompe.
        return null;
    }

    /** Inferencia del tipo Java esperado del elemento del array. */
    private static Class<?> arrayElementType(String up) {
        return switch (up) {
            case "BIGINT[]", "INTEGER[]" -> Long.class;
            case "NUMERIC[]" -> BigDecimal.class;
            case "BOOLEAN[]" -> Boolean.class;
            case "TIME[]" -> java.sql.Time.class;
            case "TEXT[]" -> String.class;
            default -> null;
        };
    }

    private static boolean isIntegerFamily(Object v) {
        return v instanceof Integer || v instanceof Long
                || v instanceof Short || v instanceof Byte
                || v instanceof BigInteger;
    }

    private static boolean isDecimalFamily(Object v) {
        return isIntegerFamily(v) /* INTEGER cabe en DECIMAL */
                || v instanceof Float || v instanceof Double
                || v instanceof BigDecimal;
    }

    /**
     * ¿El valor {@code v} es asignable / parseable al tipo
     * esperado? Conservador: si el valor es null ya lo
     * filtramos; si no, miramos la jerarquía directa.
     */
    private static boolean isCompatibleWith(Object v, Class<?> expected) {
        if (v == null) return true;
        if (expected.isInstance(v)) return true;
        // Aceptamos cualquier número entero en un BIGINT[].
        if (expected == Long.class) return isIntegerFamily(v);
        if (expected == BigDecimal.class) return isDecimalFamily(v);
        // TIME[] (y temporales en general): JSON no tiene un
        // literal nativo para hora/fecha — Jackson SIEMPRE
        // entrega String para un elemento de array como
        // "10:00:00", nunca java.sql.Time (eso sólo existe si
        // el caller lo construye a mano en Java). Exigir
        // instanceof Time aquí rechazaría cualquier body JSON
        // válido; igual que la rama escalar de TEMPORAL_TYPES
        // más abajo, aceptamos String y dejamos que el cast de
        // PG valide el formato real.
        if (expected == Time.class) return v instanceof String;
        return false;
    }

    /**
     * Serializa un valor escalar a String. El cast en SQL decide si el texto
     * es válido para el tipo destino; aquí sólo producimos una
     * representación textual razonable.
     */
    static String stringify(Object val) {
        if (val == null) return null;
        if (val instanceof String s)         return s;
        if (val instanceof Integer i)        return i.toString();
        if (val instanceof Long l)           return l.toString();
        if (val instanceof Short s)          return s.toString();
        if (val instanceof Byte b)           return b.toString();
        if (val instanceof Float f)          return f.toString();
        if (val instanceof Double d)         return d.toString();
        if (val instanceof BigDecimal bd)    return bd.toPlainString();
        if (val instanceof Boolean bo)       return bo ? "true" : "false";
        if (val instanceof java.sql.Date d)  return d.toString();
        if (val instanceof Time t)           return t.toString();
        if (val instanceof Timestamp ts)     return ts.toString();
        if (val instanceof java.util.Date dt) return new Timestamp(dt.getTime()).toString();
        if (val instanceof java.util.UUID u) return u.toString();
        if (val instanceof Enum<?> en)       return en.name();
        // Fallback: toString() del valor. Si llega un tipo raro (p.ej. un Map
        // no-BODY_RAW), lo serializamos como JSON literal y que el cast
        // decida si tiene sentido.
        return val.toString();
    }

    /**
     * Serializa un {@code List<?>} (lo que produce Jackson desde un JSON array)
     * al formato PG-array: {@code {elem1,elem2,...,elemN}}. Cada elemento se
     * serializa por {@link #stringify}; los strings se quotan con comillas
     * dobles y se escapan las comillas internas.
     *
     * <p>Si el valor ya es un array Java del tipo Java correcto
     * (p.ej. {@code String[]}, {@code Long[]}), se itera directamente.
     */
    static String toPgArray(Object val) {
        if (val == null) return null;
        List<Object> list;
        if (val instanceof List<?> l) {
            list = new java.util.ArrayList<>(l);
        } else if (val.getClass().isArray()) {
            int len = java.lang.reflect.Array.getLength(val);
            list = new java.util.ArrayList<>(len);
            for (int i = 0; i < len; i++) {
                list.add(java.lang.reflect.Array.get(val, i));
            }
        } else {
            throw new IllegalArgumentException(
                    "Se esperaba List o array, se recibió: "
                    + val.getClass().getSimpleName());
        }
        if (list.isEmpty()) return "{}";
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Object elem : list) {
            if (!first) sb.append(',');
            first = false;
            if (elem == null) {
                sb.append("NULL");
            } else if (elem instanceof String s) {
                sb.append('"');
                for (int i = 0; i < s.length(); i++) {
                    char c = s.charAt(i);
                    if (c == '"' || c == '\\') sb.append('\\');
                    sb.append(c);
                }
                sb.append('"');
            } else if (elem instanceof Boolean b) {
                sb.append(b ? "true" : "false");
            } else {
                sb.append(stringify(elem));
            }
        }
        sb.append('}');
        return sb.toString();
    }

    /**
     * Serializa un {@code Map<?,?>} como JSON literal: {@code {"k":"v",...}}.
     * Pensado para {@code BODY_RAW.X} cuando el autor quiere pasar un
     * sub-objeto completo como {@code jsonb}. No usamos Jackson para no
     * añadir una dependencia — el binder ya está en common y debe ser
     * ligero. Si los valores son heterogéneos, los strings se quotan y los
     * números/booleanos se serializan con su forma JSON.
     */
    @SuppressWarnings("unchecked")
    static String toJsonLiteral(Map<?, ?> map) {
        if (map == null) return null;
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<?, ?> e : map.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            sb.append('"').append(escapeJson(e.getKey().toString())).append('"').append(':');
            Object v = e.getValue();
            if (v == null) {
                sb.append("null");
            } else if (v instanceof Map<?, ?> nested) {
                sb.append(toJsonLiteral(nested));
            } else if (v instanceof List<?> list) {
                sb.append('[');
                boolean firstArr = true;
                for (Object item : list) {
                    if (!firstArr) sb.append(',');
                    firstArr = false;
                    if (item == null) sb.append("null");
                    else if (item instanceof String s) sb.append('"').append(escapeJson(s)).append('"');
                    else if (item instanceof Number || item instanceof Boolean) sb.append(stringify(item));
                    else if (item instanceof Map<?, ?> m) sb.append(toJsonLiteral(m));
                    else sb.append('"').append(escapeJson(stringify(item))).append('"');
                }
                sb.append(']');
            } else if (v instanceof String s) {
                sb.append('"').append(escapeJson(s)).append('"');
            } else if (v instanceof Number || v instanceof Boolean) {
                sb.append(stringify(v));
            } else {
                sb.append('"').append(escapeJson(stringify(v))).append('"');
            }
        }
        sb.append('}');
        return sb.toString();
    }

    private static String escapeJson(String s) {
        StringBuilder sb = new StringBuilder(s.length() + 2);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20) sb.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }
}