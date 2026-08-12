package com.co.eurekatic.common.query;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.math.BigDecimal;
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
        Map<String, String> types = paramTypes == null ? Map.of() : paramTypes;
        MapSqlParameterSource src = new MapSqlParameterSource();
        if (values == null) return src;

        for (Map.Entry<String, Object> e : values.entrySet()) {
            String key = e.getKey();
            Object val = e.getValue();
            String declaredType = types.get(key);

            if (val == null) {
                // null: no se bindea. PG interpreta el placeholder como NULL
                // sólo si el cast lo permite; si no, hay que usar COALESCE en SQL.
                // Saltarse el addValue evita que JDBC mande setObject(k, null)
                // con tipo desconocido.
                continue;
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
        }
        return src;
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