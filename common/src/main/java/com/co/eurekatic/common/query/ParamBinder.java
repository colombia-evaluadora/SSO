package com.co.eurekatic.common.query;

import org.springframework.jdbc.core.SqlTypeValue;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.support.AbstractSqlTypeValue;

import java.lang.reflect.Array;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.sql.Types;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Construye un {@link MapSqlParameterSource} con tipos JDBC explícitos
 * para los placeholders declarados en {@code paramTypes}, y deja que
 * Spring derive el tipo del valor para los demás. Es el pegamento entre
 * la metadata del catálogo ({@code QUERY.PARAM_TYPES}) y el runtime de
 * bind ({@code PreparedStatement.setObject}).
 *
 * <p><b>Coerción client-side (V49)</b>: el query-service espera que
 * los consumidores (admin-ui, otros microservicios, integraciones
 * externas) manden los valores en texto — el binder convierte cada
 * valor al tipo Java del set curado antes del bind. Esto evita que
 * el autor del catálogo tenga que pensar en cómo serializa Jackson
 * cada valor (p. ej. un {@code [1,2,3]} que llega como
 * {@code List<Long} frente a un {@code ["1","2","3"]} que llega como
 * {@code List<String>}) — los dos bindean correctamente porque aquí
 * se convierten a {@code Long[]} antes de {@code createArrayOf}.
 *
 * <p><b>Tipos escalares</b>: si el valor ya es del tipo Java destino
 * se pasa tal cual; si llega como {@code String} (lo más común desde
 * JSON) se parsea al tipo declarado. Si el parseo falla se lanza un
 * {@code 400} con el mensaje del error, idéntico al que daría PG
 * pero sin tirar la conexión.
 *
 * <p><b>Tipos array</b>: el valor debe ser {@code List<?>} (lo que
 * produce Jackson para un JSON array). Cada elemento se coerce al
 * tipo escalar correspondiente ({@code List<String>} con declarado
 * {@code BIGINT[]} → {@code Long[]}); luego se envuelve en un
 * {@link AbstractSqlTypeValue} que delega {@link Connection#createArrayOf}
 * a la {@code Connection} activa. Abrir conexión por cada parámetro
 * sería prohibitivo; el wrapper lo resuelve en la fase de bind.
 *
 * <p><b>Legacy / no declarado</b>: si la key no aparece en
 * {@code paramTypes}, no se aplica coerción ni sqlType —
 * comportamiento idéntico al de antes de V49. Una fila sin
 * {@code PARAM_TYPES} o con un placeholder que el autor olvidó
 * tipar entra por aquí.
 */
public final class ParamBinder {

    private ParamBinder() {}

    /** Mapeo de alias en mayúsculas a nombre PG en minúsculas para {@code createArrayOf}. */
    private static final Map<String, String> PG_ARRAY_ELEMENT = Map.of(
            "TEXT[]",     "text",
            "BIGINT[]",   "int8",
            "INTEGER[]",  "int4",
            "NUMERIC[]",  "numeric",
            "BOOLEAN[]",  "bool",
            "TIME[]",     "time"
    );

    /** Tipo Java del elemento para cada alias de array — para construir el {@code Object[]} tipado. */
    private static final Map<String, Class<?>> ARRAY_ELEMENT_CLASS = Map.of(
            "TEXT[]",     String.class,
            "BIGINT[]",   Long.class,
            "INTEGER[]",  Integer.class,
            "NUMERIC[]",  BigDecimal.class,
            "BOOLEAN[]",  Boolean.class,
            "TIME[]",     java.sql.Time.class
    );

    public static MapSqlParameterSource build(Map<String, Object> values,
                                              Map<String, String> paramTypes) {
        Map<String, String> types = paramTypes == null ? Map.of() : paramTypes;
        MapSqlParameterSource src = new MapSqlParameterSource();
        if (values == null) return src;

        for (Map.Entry<String, Object> e : values.entrySet()) {
            String key = e.getKey();
            Object val = e.getValue();
            String declared = types.get(key);

            if (declared == null) {
                // Sin tipo declarado → comportamiento anterior: Spring
                // auto-derive del valor runtime.
                src.addValue(key, val);
                continue;
            }

            Integer jdbcType = ParamTypes.JDBC_TYPES.get(declared);
            if (jdbcType == null) {
                // Tipo declarado pero desconocido — la validación en
                // sso-admin ya lo habría rechazado, pero defensivamente
                // caemos al auto-derive para no romper el runtime.
                src.addValue(key, val);
                continue;
            }

            try {
                if (ParamTypes.ARRAY_TYPES.contains(declared)) {
                    src.addValue(key, arrayValue(declared, val), Types.ARRAY);
                } else {
                    Object coerced = coerceScalar(val, declared);
                    src.addValue(key, coerced, jdbcType);
                }
            } catch (IllegalArgumentException ex) {
                // Coerción imposible (ej. BIGINT declarado, valor "abc"
                // — NumberFormatException extiende IllegalArgumentException
                // y se captura aquí). Propagamos como 400 antes de
                // tocar la conexión.
                throw new IllegalArgumentException(
                        "No se puede bindear el parámetro '" + key
                        + "' al tipo declarado " + declared + ": "
                        + ex.getMessage());
            }
        }
        return src;
    }

    /**
     * Convierte un valor escalar al tipo Java del set curado.
     *
     * <p>Reglas por declarado:
     * <ul>
     *   <li>{@code TEXT} / {@code VARCHAR}: siempre String, sin coerción.</li>
     *   <li>{@code JSONB} / {@code JSON}: String; el driver PG acepta
     *       JSON como texto y hace el cast al tipo de columna.</li>
     *   <li>{@code UUID}: String; el driver parsea con
     *       {@link java.util.UUID#fromString}.</li>
     *   <li>{@code BIGINT} / {@code INTEGER} / {@code SMALLINT}:
     *       {@link Long} / {@link Integer} / {@link Short}. Si llega
     *       como String se parsea.</li>
     *   <li>{@code NUMERIC}: {@link BigDecimal} — parsing estricto,
     *       nunca {@code double} para no perder precisión.</li>
     *   <li>{@code BOOLEAN}: {@link Boolean} — acepta "true"/"false"
     *       además del booleano nativo (Jackson en JSON suele dar el
     *       nativo).</li>
     *   <li>{@code DATE}: {@link java.sql.Date} desde String ISO
     *       {@code yyyy-MM-dd}.</li>
     *   <li>{@code TIME}: {@link java.sql.Time} desde String
     *       {@code HH:mm:ss[.fffffffff]}.</li>
     *   <li>{@code TIMESTAMP}: {@link Timestamp} desde String
     *       {@code yyyy-MM-dd HH:mm:ss[.fffffffff]}.</li>
     *   <li>{@code TIMESTAMPTZ}: se pasa como String; el driver PG
     *       parsea con zona horaria del parámetro de sesión.</li>
     *   <li>{@code CHAR(1)}: {@code String} de longitud 1. Útil para
     *       flags de un solo carácter ({@code 'S'/'N'}, {@code 'A'/'I'})
     *       muy comunes en este codebase (ver V22 academic schema).</li>
     * </ul>
     */
    private static Object coerceScalar(Object val, String declaredType) {
        if (val == null) return null;

        switch (declaredType) {
            case "TEXT":
            case "VARCHAR":
            case "JSONB":
            case "JSON":
            case "UUID":
            case "TIMESTAMPTZ":
                // El driver PG sabe hacer el cast desde String. Si
                // llega como otro tipo (p. ej. UUID nativo) lo
                // pasamos tal cual.
                return val;

            case "BIGINT":
                if (val instanceof Long l) return l;
                return Long.parseLong(val.toString().trim());

            case "INTEGER":
                if (val instanceof Integer i) return i;
                // Jackson suele dar Long para números enteros sin
                // fracción; casteamos a int si entra en rango.
                if (val instanceof Long l) {
                    if (l < Integer.MIN_VALUE || l > Integer.MAX_VALUE) {
                        throw new NumberFormatException(
                                "Valor fuera de rango INTEGER: " + l);
                    }
                    return l.intValue();
                }
                return Integer.parseInt(val.toString().trim());

            case "SMALLINT":
                if (val instanceof Short s) return s;
                if (val instanceof Long l) {
                    if (l < Short.MIN_VALUE || l > Short.MAX_VALUE) {
                        throw new NumberFormatException(
                                "Valor fuera de rango SMALLINT: " + l);
                    }
                    return l.shortValue();
                }
                if (val instanceof Integer i) {
                    if (i < Short.MIN_VALUE || i > Short.MAX_VALUE) {
                        throw new NumberFormatException(
                                "Valor fuera de rango SMALLINT: " + i);
                    }
                    return i.shortValue();
                }
                return Short.parseShort(val.toString().trim());

            case "NUMERIC":
                if (val instanceof BigDecimal bd) return bd;
                if (val instanceof Long l) return BigDecimal.valueOf(l);
                if (val instanceof Integer i) return BigDecimal.valueOf(i);
                if (val instanceof Double d) return BigDecimal.valueOf(d);
                return new BigDecimal(val.toString().trim());

            case "BOOLEAN":
                if (val instanceof Boolean b) return b;
                // Aceptamos "true"/"false"/"1"/"0" — Boolean.parseBoolean
                // es estricto, así que lo manejamos a mano.
                String s = val.toString().trim().toLowerCase(Locale.ROOT);
                if (s.equals("true") || s.equals("1") || s.equals("yes")) return Boolean.TRUE;
                if (s.equals("false") || s.equals("0") || s.equals("no")) return Boolean.FALSE;
                throw new IllegalArgumentException(
                        "Boolean inválido: '" + val + "' (esperado true/false/1/0/yes/no)");

            case "DATE":
                if (val instanceof java.sql.Date d) return d;
                return java.sql.Date.valueOf(val.toString().trim());

            case "TIME":
                if (val instanceof java.sql.Time t) return t;
                // java.sql.Time.valueOf exige HH:mm:ss (con fracciones
                // opcionales). Si el front manda "10:30" lo extendemos
                // a "10:30:00" para que no rebote por algo que PG
                // aceptaría tranquilamente.
                String ts = val.toString().trim();
                if (ts.matches("\\d{1,2}:\\d{2}")) {
                    ts = ts + ":00";
                }
                return java.sql.Time.valueOf(ts);

            case "CHAR(1)":
                String cs = val.toString();
                if (cs.length() > 1) {
                    throw new IllegalArgumentException(
                            "CHAR(1) admite un solo carácter; llegó '"
                            + cs + "' (longitud=" + cs.length() + ")");
                }
                return cs;

            case "TIMESTAMP":
                if (val instanceof Timestamp t) return t;
                return Timestamp.valueOf(val.toString().trim());

            default:
                // Tipo declarado no reconocido por la coerción (no
                // debería pasar — la validación en sso-admin ya filtra).
                return val;
        }
    }

    /**
     * Envuelve el valor (que debe ser un JSON array → {@code List<?>})
     * en un {@link SqlTypeValue} que llama {@code createArrayOf} con
     * los elementos ya coercidos al tipo escalar del array. Por
     * ejemplo, declarado {@code BIGINT[]} con valor
     * {@code List<String>["1","2","3"]} → {@code Long[] {1L,2L,3L}}
     * que el driver serializa como {@code int8[]}.
     *
     * <p>Si el valor ya es un array del tipo correcto (p. ej. el
     * binario NIO de Jackson, o un cliente que prefiere enviar
     * {@code String[]} directamente), se pasa tal cual.
     */
    private static SqlTypeValue arrayValue(String declaredType, Object val) {
        String elementType = PG_ARRAY_ELEMENT.get(declaredType.toUpperCase(Locale.ROOT));
        Class<?> elementClass = ARRAY_ELEMENT_CLASS.get(declaredType.toUpperCase(Locale.ROOT));
        if (elementType == null || elementClass == null) {
            // No debería pasar — ParamTypes.ARRAY_TYPES ya lo filtra.
            throw new IllegalArgumentException(
                    "Tipo array no soportado: " + declaredType);
        }

        final Object[] arr;
        if (val == null) {
            arr = null;
        } else if (val instanceof List<?> list) {
            // Jackson produce List<Object> desde JSON array. Cada
            // elemento se coerce al tipo escalar correspondiente.
            arr = (Object[]) Array.newInstance(elementClass, list.size());
            String scalarType = declaredType.substring(0, declaredType.length() - 2);
            for (int i = 0; i < list.size(); i++) {
                arr[i] = coerceScalar(list.get(i), scalarType);
            }
        } else if (val.getClass() == elementClass.arrayType()) {
            // Ya es String[] / Long[] / etc. — pasamos tal cual.
            arr = (Object[]) val;
        } else if (val instanceof Object[] oa) {
            // Array de otro tipo — coerce elemento a elemento.
            arr = (Object[]) Array.newInstance(elementClass, oa.length);
            String scalarType = declaredType.substring(0, declaredType.length() - 2);
            for (int i = 0; i < oa.length; i++) {
                arr[i] = coerceScalar(oa[i], scalarType);
            }
        } else {
            throw new IllegalArgumentException(
                    "Tipo array declarado (" + declaredType
                    + ") pero el valor no es List ni array: "
                    + val.getClass().getSimpleName());
        }

        final String elementTypeFinal = elementType;
        return new AbstractSqlTypeValue() {
            @Override
            protected Object createTypeValue(Connection c, int sqlType, String typeName) throws SQLException {
                return arr == null ? null : c.createArrayOf(elementTypeFinal, arr);
            }
        };
    }
}