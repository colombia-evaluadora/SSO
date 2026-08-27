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
 * <p><b>Arrays JSON nativos en un JSONB escalar (V63)</b>: cuando el tipo
 * declarado es {@code JSONB}/{@code JSON} (no {@code JSONB[]}) y el valor
 * es un {@code List} — el caso de un parámetro {@code jsonb} de PL/pgSQL
 * que internamente contiene un array de registros, como
 * {@code fn_escala_guardar_bulk(p_scales jsonb, ...)} — se serializa como
 * literal JSON array ({@code [{"k":"v"},{"k":"w"}]}). Antes de V63 el
 * cliente tenía que pre-serializar el array a mano como {@code String}
 * ({@code "SCALES": "[{...}]"}); ahora un array nativo
 * ({@code "SCALES": [{...}]}) también funciona — más ergonómico y lo que
 * cualquier cliente REST esperaría de un campo JSON. Ver
 * {@link #toJsonArrayLiteral}.
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
 *
 * <p><b>V62 (nulabilidad)</b>: por defecto, todo parámetro declarado
 * acepta {@code null} — enviarlo explícito o simplemente omitir el
 * campo bindea {@code NULL} de SQL. Antes de V62 ambos casos dejaban
 * el placeholder sin valor en el {@link MapSqlParameterSource}, y
 * como el SQL sí lo referenciaba (el {@code cast(:x as TIPO)} que
 * inserta {@link SqlRewriter}), Spring reventaba con una excepción
 * que no es {@link java.sql.SQLException} — de ahí el 500 opaco sin
 * log que documenta la spec 2026-08-13. Un autor del catálogo marca
 * un parámetro como <b>obligatorio</b> añadiendo {@code '!'} al tipo
 * ({@code "BIGINT!"}, ver {@link ParamTypes#parseDeclaration}); ahí
 * {@code null} u omitir el campo responde {@code 400} nombrando el
 * parámetro en vez de bindear NULL o reventar.
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
        Map<String, Object> safeValues = values == null ? Map.of() : values;

        for (Map.Entry<String, Object> e : safeValues.entrySet()) {
            String key = e.getKey();
            Object val = e.getValue();
            String declaredTypeRaw = types.get(key);
            if (declaredTypeRaw == null) {
                // V60-bis — el cliente puede haber escrito la
                // key en cualquier caja. Buscamos la
                // representación canónica (MAYÚSCULAS +
                // namespace prefix) contra el catálogo.
                String canonical = canonicalLookupKey(key);
                if (canonical != null) {
                    declaredTypeRaw = types.get(canonical);
                }
            }
            ParamTypes.Declaration decl = ParamTypes.parseDeclaration(declaredTypeRaw);
            String declaredType = decl.baseType();

            if (val == null) {
                requireNullableOr400(key, declaredTypeRaw, decl);
                // V62 — antes esto simplemente saltaba el
                // addValue: el placeholder quedaba SIN valor en
                // el MapSqlParameterSource, y como el SQL sí lo
                // referencia (vía el cast que insertó
                // SqlRewriter), Spring reventaba con
                // "no value supplied for the SQL parameter" —
                // una excepción que no es SQLException, así que
                // GlobalExceptionHandler.handleDataAccess la
                // devolvía como 500 opaco sin loguear nada (ver
                // spec 2026-08-13). Bindear NULL explícito deja
                // que PG resuelva {@code cast(NULL as TIPO)},
                // válido para cualquier tipo.
                bindWithAliases(src, key, null);
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
                } else if (isScalarJsonType(declaredType) && val instanceof List<?> listVal) {
                    // V63 — array nativo para un JSONB/JSON escalar (no
                    // JSONB[]): el cliente ya no necesita pre-serializar
                    // el array a String a mano.
                    serialized = toJsonArrayLiteral(listVal);
                } else if (isScalarJsonType(declaredType) && val instanceof Map<?, ?> mapVal) {
                    serialized = toJsonLiteral(mapVal);
                } else if (key.startsWith(ParamNamespace.BODY_RAW + ".") && val instanceof Map) {
                    // Fallback para BODY_RAW.X con Map SIN tipo declarado
                    // (declaredType == null) — el guard runtime de
                    // QueryService ya exige tipo para todo BODY_RAW.* en
                    // producción, pero este método también lo llaman
                    // callers que no pasan por esa guardia.
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
            bindWithAliases(src, key, serialized);
        }

        // V62 — parámetros DECLARADOS que el cliente ni siquiera
        // mandó (la key no aparece en absoluto en `values`, ni
        // como null explícito). Antes del fix de arriba esto ya
        // era el mismo 500 opaco — sólo que el bucle de arriba ni
        // llegaba a verlo, porque no hay entrada en `values` que
        // recorrer. Un campo omitido y uno enviado en null son la
        // misma "ausencia de valor" desde el punto de vista de
        // SQL, así que se tratan igual: obligatorio → 400 nombrando
        // el parámetro; opcional (default) → bind NULL.
        for (Map.Entry<String, String> te : types.entrySet()) {
            String declaredKey = te.getKey();
            if (isPresent(safeValues, declaredKey)) continue; // ya procesado arriba
            ParamTypes.Declaration decl = ParamTypes.parseDeclaration(te.getValue());
            requireNullableOr400(declaredKey, te.getValue(), decl);
            bindWithAliases(src, declaredKey, null);
        }

        return src;
    }

    /** Lanza 400 si {@code decl} es obligatorio; no hace nada si es nullable. */
    private static void requireNullableOr400(String key, String declaredTypeRaw,
                                              ParamTypes.Declaration decl) {
        if (declaredTypeRaw != null && !decl.nullable()) {
            throw new IllegalArgumentException(
                    "El parámetro '" + key + "' es obligatorio (tipo " + decl.baseType()
                    + ") y no puede omitirse ni enviarse como null.");
        }
    }

    /**
     * ¿Existe alguna entrada en {@code values} que el bucle principal
     * de {@link #buildStrict} habría emparejado con {@code declaredKey}?
     * Espejo inverso de la búsqueda hacia adelante (key del cliente →
     * {@link #canonicalLookupKey} → key declarada) que ya hace ese
     * bucle — necesario para distinguir "declarado pero nunca
     * enviado" de "ya se procesó arriba" en el segundo paso.
     */
    private static boolean isPresent(Map<String, Object> values, String declaredKey) {
        if (values.containsKey(declaredKey)) return true;
        for (String rawKey : values.keySet()) {
            if (rawKey.equalsIgnoreCase(declaredKey)) return true;
            String canonical = canonicalLookupKey(rawKey);
            if (declaredKey.equals(canonical)) return true;
        }
        return false;
    }

    /**
     * Bindea {@code serializedOrNull} bajo {@code key} y sus variantes
     * canónicas — el mismo esquema de tres alias que V60-bis introdujo
     * (mayúscula, minúscula, forma canónica con namespace), ahora
     * compartido entre el camino "valor real" y el camino "NULL"
     * (V62) para no duplicar la lógica de aliasing.
     *
     * <p>Tres aliases, igual que antes:
     * <ul>
     *   <li>canonical: namespace-prefixado en MAYÚSCULAS ({@code BODY.X})
     *       — para SQL con placeholder moderno {@code :BODY.X}.</li>
     *   <li>upper: mayúsculas — para SQL legacy con {@code :id} en mayúsculas.</li>
     *   <li>lower: minúsculas — para SQL legacy con {@code :id} en minúsculas.</li>
     * </ul>
     * Spring {@code NamedParameterUtils} es case-sensitive sobre los
     * placeholders del SQL, así que con los tres aliases el bind
     * funciona en cualquier combinación de cajas y namespaces.
     */
    private static void bindWithAliases(MapSqlParameterSource src, String key,
                                        String serializedOrNull) {
        src.addValue(key, serializedOrNull);
        String upper = key.toUpperCase(java.util.Locale.ROOT);
        String lower = key.toLowerCase(java.util.Locale.ROOT);
        String canonical = canonicalLookupKey(key);
        if (canonical != null && !canonical.equals(key)) {
            src.addValue(canonical, serializedOrNull);
        }
        if (!upper.equals(key) && !upper.equals(canonical)) {
            src.addValue(upper, serializedOrNull);
        }
        if (!lower.equals(key) && !lower.equals(canonical) && !lower.equals(upper)) {
            src.addValue(lower, serializedOrNull);
        }
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

    /**
     * ¿{@code declaredType} es JSONB/JSON escalar (no {@code JSONB[]},
     * que va por {@link ParamTypes#ARRAY_TYPES}/{@link #toPgArray})?
     * {@code declaredType} ya viene sin el sufijo de nulabilidad — es
     * el tipo base que devuelve {@link ParamTypes#parseDeclaration}.
     */
    private static boolean isScalarJsonType(String declaredType) {
        return "JSONB".equals(declaredType) || "JSON".equals(declaredType);
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

        // JSONB / JSON — aceptamos Map (objeto), List (array) o
        // String (un JSON ya serializado por el cliente, objeto o
        // array). V63: antes un List se rechazaba acá y obligaba
        // al cliente a pre-serializar el array a mano
        // ({@code "SCALES": "[{...}]"}) — ahora el binder serializa
        // el array nativo correctamente (ver toJsonArrayLiteral),
        // así que un array real ({@code "SCALES": [{...}]}) es tan
        // válido como el objeto o el String pre-serializado.
        if ("JSONB".equals(up) || "JSON".equals(up)) {
            if (val instanceof Map || val instanceof List || val instanceof String) return null;
            return "El parámetro '" + key + "' se declaró como " + up
                    + " pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". Usa un objeto {...}, un array [...], o un string ya serializado.";
        }

        // Booleano
        //
        // V61 — además de un Boolean real, aceptamos el String
        // literal "true"/"false" (cualquier caja). No es sólo
        // laxitud: un :QUERY.X declarado BOOLEAN es
        // estructuralmente imposible de satisfacer con un
        // Boolean real, porque QueryPathController arma los
        // valores de QUERY con
        // {@code @RequestParam Map<String, String>} — un query
        // string HTTP no tiene forma de transportar un tipo
        // JSON, sólo texto. Antes de este cambio TODO
        // {@code QUERY.*: BOOLEAN} del catálogo era inalcanzable
        // para cualquier cliente real, no sólo para el harness
        // de pruebas (caso detectado en
        // {@code QUERY.SOLO_SIN_DOCENTE} de
        // {@code fn_asignacion_pool}). El valor sigue viajando
        // como texto — {@code stringify} ya devuelve el String
        // tal cual — así que el {@code cast(:x as boolean)} que
        // inserta {@code SqlRewriter} termina de validarlo en
        // PG. Seguimos rechazando "0"/"1"/"S"/"N": la regla
        // explícita sigue siendo sólo true/false, como dice el
        // mensaje de error.
        if ("BOOLEAN".equals(up)) {
            if (val instanceof Boolean) return null;
            if (val instanceof String s
                    && ("true".equalsIgnoreCase(s) || "false".equalsIgnoreCase(s))) {
                return null;
            }
            return "El parámetro '" + key + "' se declaró como BOOLEAN pero el cliente envió "
                    + val.getClass().getSimpleName()
                    + ". Verifica que el JSON use true/false y no 0/1 o \"S\"/\"N\".";
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
            // V61 — mismo tratamiento que TIME[]: JSON no tiene
            // literal nativo de fecha/hora, así que el elemento
            // "esperado" real es siempre String (ver isCompatibleWith).
            case "DATE[]" -> java.sql.Date.class;
            case "TIMESTAMP[]", "TIMESTAMPTZ[]" -> Timestamp.class;
            case "TEXT[]" -> String.class;
            // V61-bis — el elemento de JSONB[] es un sub-objeto
            // (Map, lo que Jackson entrega para un {...} anidado)
            // o, si el cliente ya lo mandó serializado, un String
            // con el literal JSON (ver isCompatibleWith).
            case "JSONB[]" -> Map.class;
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
        // TIME[] / DATE[] / TIMESTAMP[] / TIMESTAMPTZ[] (y
        // temporales en general): JSON no tiene un literal
        // nativo para fecha/hora — Jackson SIEMPRE entrega
        // String para un elemento de array como "10:00:00" o
        // "2026-08-12", nunca java.sql.Time/Date/Timestamp (eso
        // sólo existe si el caller lo construye a mano en Java).
        // Exigir instanceof aquí rechazaría cualquier body JSON
        // válido; igual que la rama escalar de TEMPORAL_TYPES
        // más abajo, aceptamos String y dejamos que el cast de
        // PG valide el formato real.
        if (expected == Time.class
                || expected == java.sql.Date.class
                || expected == Timestamp.class) {
            return v instanceof String;
        }
        // JSONB[]: el elemento "Map" ya lo cubre expected.isInstance(v)
        // arriba (Map es una interfaz — isInstance funciona igual).
        // Lo único que falta es aceptar String: un cliente que ya
        // serializó el objeto a texto ({@code "{\"k\":\"v\"}"}) es
        // tan válido como el sub-objeto — el cast a jsonb[] en PG
        // acepta ambos.
        if (expected == Map.class) return v instanceof String;
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
                appendQuotedPgArrayElement(sb, s);
            } else if (elem instanceof Boolean b) {
                sb.append(b ? "true" : "false");
            } else if (elem instanceof Map<?, ?> m) {
                // JSONB[]: el elemento es un sub-objeto — se serializa a
                // texto JSON y ESE texto se quota como cualquier String,
                // igual que el resto de elementos del array. El cast
                // `as jsonb[]` en SQL valida que cada elemento sea JSON
                // bien formado.
                appendQuotedPgArrayElement(sb, toJsonLiteral(m));
            } else {
                sb.append(stringify(elem));
            }
        }
        sb.append('}');
        return sb.toString();
    }

    /**
     * Quota {@code raw} como elemento string de un literal PG-array
     * ({@code "..."}), escapando comilla doble y backslash — las dos
     * reglas del formato de array de PostgreSQL. Se usa tanto para
     * elementos {@code String} planos como para el texto JSON que
     * produce {@link #toJsonLiteral} en un {@code JSONB[]}: en ambos
     * casos el contenido es "un string" desde el punto de vista del
     * parser de arrays de PG, sin importar que ese string a su vez
     * contenga JSON con sus propias comillas.
     */
    private static void appendQuotedPgArrayElement(StringBuilder sb, String raw) {
        sb.append('"');
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c == '"' || c == '\\') sb.append('\\');
            sb.append(c);
        }
        sb.append('"');
    }

    /**
     * Serializa un {@code Map<?,?>} como JSON literal: {@code {"k":"v",...}}.
     * Pensado para {@code BODY_RAW.X} cuando el autor quiere pasar un
     * sub-objeto completo como {@code jsonb}. No usamos Jackson para no
     * añadir una dependencia — el binder ya está en common y debe ser
     * ligero. Si los valores son heterogéneos, los strings se quotan y los
     * números/booleanos se serializan con su forma JSON.
     */
    static String toJsonLiteral(Map<?, ?> map) {
        if (map == null) return null;
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<?, ?> e : map.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            sb.append('"').append(escapeJson(e.getKey().toString())).append('"').append(':');
            appendJsonValue(sb, e.getValue());
        }
        sb.append('}');
        return sb.toString();
    }

    /**
     * V63 — serializa un {@code List<?>} (lo que produce Jackson desde un
     * JSON array) como literal JSON array: {@code [elem1,elem2,...]}. Es
     * el contrapunto de {@link #toJsonLiteral} para cuando el valor de un
     * {@code BODY_RAW.X} declarado {@code JSONB}/{@code JSON} es
     * directamente un array, no un objeto — el caso de
     * {@code fn_escala_guardar_bulk}, {@code fn_subject_guardar_bulk},
     * etc., cuyo parámetro {@code jsonb} escalar contiene un array de
     * registros ({@code [{"...":"..."},{"...":"..."}]}), no un objeto.
     *
     * <p>Antes de V63 el cliente tenía que pre-serializar el array a
     * mano como {@code String} ({@code "SCALES": "[{...}]"}) porque
     * {@link #validateAgainstDeclared} rechazaba un {@code List} crudo
     * para JSONB escalar, y aun sorteando esa validación la
     * serialización caía al fallback de {@link #stringify} —
     * {@code List.toString()} de Java, que no es JSON válido. Ahora se
     * acepta el array nativo (más ergonómico y lo que cualquier
     * cliente REST esperaría) y se serializa acá correctamente; la
     * forma pre-serializada como {@code String} se sigue aceptando
     * también, sin cambios.
     */
    static String toJsonArrayLiteral(List<?> list) {
        if (list == null) return null;
        StringBuilder sb = new StringBuilder("[");
        boolean first = true;
        for (Object item : list) {
            if (!first) sb.append(',');
            first = false;
            appendJsonValue(sb, item);
        }
        sb.append(']');
        return sb.toString();
    }

    /**
     * Serializa un valor JSON cualquiera (lo que puede salir de un
     * árbol Jackson: {@code null}, {@code Map}, {@code List}, String,
     * Number, Boolean, o cualquier otro tipo como fallback a texto
     * quotado) y lo apendiza a {@code sb}. Punto único de dispatch
     * compartido por {@link #toJsonLiteral} (valores de un objeto) y
     * {@link #toJsonArrayLiteral} (elementos de un array) — antes esta
     * lógica vivía duplicada e inline dentro de {@code toJsonLiteral},
     * y la rama de List anidada dentro de un Map no manejaba una lista
     * DENTRO de otra lista (caía al fallback de texto quotado); al
     * unificar en un método recursivo, ese caso también queda cubierto.
     */
    private static void appendJsonValue(StringBuilder sb, Object v) {
        if (v == null) {
            sb.append("null");
        } else if (v instanceof Map<?, ?> nested) {
            sb.append(toJsonLiteral(nested));
        } else if (v instanceof List<?> nested) {
            sb.append(toJsonArrayLiteral(nested));
        } else if (v instanceof String s) {
            sb.append('"').append(escapeJson(s)).append('"');
        } else if (v instanceof Number || v instanceof Boolean) {
            sb.append(stringify(v));
        } else {
            sb.append('"').append(escapeJson(stringify(v))).append('"');
        }
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