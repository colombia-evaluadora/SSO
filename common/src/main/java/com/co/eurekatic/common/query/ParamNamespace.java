package com.co.eurekatic.common.query;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;

/**
 * Los cuatro orígenes posibles de un parámetro y cómo se nombran.
 *
 * <p>Antes todos los valores caían en un mapa plano: las variables
 * de ruta, los query params, el body aplanado y lo inyectado del
 * JWT. Eso tenía dos consecuencias malas. Una, que mirando una SQL
 * no se sabía qué controla el llamante y qué el sistema — la
 * distinción que importa para razonar sobre seguridad. Y dos, que
 * podían pisarse entre sí en silencio.
 *
 * <p>Con prefijo obligatorio la colisión deja de ser improbable y
 * pasa a ser imposible, que es una garantía distinta.
 */
public final class ParamNamespace {

    private ParamNamespace() {}

    /** Variables de la ruta. Las controla el llamante. */
    public static final String PARAM = "PARAM";
    /** Query string. Lo controla el llamante. */
    public static final String QUERY = "QUERY";
    /** Cuerpo JSON aplanado con puntos. Lo controla el llamante. */
    public static final String BODY = "BODY";
    /**
     * V49-bis — Cuerpo JSON sin aplanar: cada clave top-level del body se
     * expone con su valor completo (un sub-objeto Map o un array) bajo
     * {@code BODY_RAW.NOMBRE}. Pensado para pasar sub-árboles completos
     * como {@code JSONB} al SQL via {@code cast(:BODY_RAW.X as jsonb)},
     * donde el aplanamiento con puntos no aplica.
     */
    public static final String BODY_RAW = "BODY_RAW";
    /** Derivado del JWT verificado. NO lo controla el llamante. */
    public static final String CONTEXT = "CONTEXT";

    /**
     * Forma de un nombre de parámetro: ASCII, MAYÚSCULA, empezando
     * por letra. Es la definición única para todo el sistema — la
     * usan tanto las variables de ruta ({@link PathTemplateSyntax})
     * como las claves que llegan en el query string y en el body.
     *
     * <p>La restricción no es estilística, es necesaria. El parser
     * de parámetros de Spring corta un nombre en cuanto encuentra
     * uno de sus separadores, entre los que está el guion. Una
     * clave {@code ?page-size=1} produciría {@code :QUERY.PAGE}
     * seguido de {@code -SIZE} suelto en mitad del SQL: ni error de
     * parseo ni resultado correcto. Rechazarla al entrar es la
     * única forma de que ese caso no exista.
     *
     * <p>Los acentos y la eñe quedan fuera por la misma razón que
     * en las rutas: un nombre de parámetro es un identificador que
     * alguien tiene que poder teclear igual en el SQL, en la URL y
     * en el formulario. La convención es transliterar —
     * {@code ANIO}, no {@code AÑO}.
     */
    private static final java.util.regex.Pattern VALID_NAME =
            java.util.regex.Pattern.compile("[A-Z][A-Z0-9_]*");

    /**
     * ¿Es {@code name} un nombre de parámetro válido? Se expone
     * para que {@link PathTemplateSyntax} aplique exactamente la
     * misma regla a las variables de ruta: si las dos definiciones
     * pudieran divergir, una plantilla válida podría producir un
     * bind imposible de escribir en el SQL.
     */
    public static boolean isValidName(String name) {
        return name != null && VALID_NAME.matcher(name).matches();
    }

    /**
     * Pasa una clave del llamante a su forma canónica y verifica
     * que sea un nombre de parámetro escribible.
     *
     * <p>Se rechaza en vez de transliterar. Convertir {@code AÑO}
     * a {@code ANIO} por detrás significaría que la clave que el
     * cliente envía y el bind que el autor escribe en el SQL no se
     * parecen, y nadie podría deducir uno del otro leyendo el
     * otro. Mejor un 400 que diga exactamente qué escribir.
     */
    private static String normalizeName(String rawKey) {
        String upper = rawKey.toUpperCase(Locale.ROOT);
        if (!isValidName(upper)) {
            throw new IllegalArgumentException(
                    "La clave '" + rawKey + "' no es un nombre de parámetro "
                    + "válido: sólo se admiten A-Z, 0-9 y '_', empezando por "
                    + "letra. Translitera los acentos y la eñe — por ejemplo "
                    + "'ANIO' en vez de 'AÑO'.");
        }
        return upper;
    }

    /**
     * Copia {@code source} en {@code target} prefijando con el
     * namespace y pasando la clave a MAYÚSCULA.
     *
     * <p>Se normaliza el NOMBRE, nunca el VALOR: un nombre es un
     * identificador y puede canonicalizarse, un valor es dato y
     * pasarlo a mayúscula destrozaría emails, códigos o UUIDs.
     *
     * @throws IllegalArgumentException si dos claves sólo se
     *         diferencian por la caja. Elegir una en silencio
     *         sería justo el tipo de fallo invisible que este
     *         diseño existe para eliminar.
     */
    public static void putAll(Map<String, Object> target,
                              String namespace,
                              Map<String, ?> source) {
        if (source == null || source.isEmpty()) {
            return;
        }
        Map<String, String> originalByUpper = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : source.entrySet()) {
            String upper = normalizeName(e.getKey());
            String previous = originalByUpper.putIfAbsent(upper, e.getKey());
            if (previous != null) {
                throw new IllegalArgumentException(
                        "Las claves '" + previous + "' y '" + e.getKey()
                        + "' sólo se diferencian por mayúsculas y ambas "
                        + "resolverían a :" + namespace + "." + upper
                        + ". Envía sólo una.");
            }
            target.put(namespace + "." + upper, e.getValue());
        }
    }

    /**
     * Aplana un JSON anidado a rutas con punto, en MAYÚSCULA:
     * {@code {"filtros":{"zona":1}}} → {@code BODY.FILTROS.ZONA=1}.
     *
     * <p>Los arrays se dejan intactos: JDBC sabe bindear una lista
     * a un parámetro, y trocearla por índice produciría nombres
     * que nadie puede escribir en una SQL.
     */
    public static Map<String, Object> flatten(Map<String, ?> body, String prefix) {
        Map<String, Object> out = new LinkedHashMap<>();
        flattenInto(out, body, prefix);
        return out;
    }

    private static void flattenInto(Map<String, Object> out,
                                    Map<String, ?> body,
                                    String prefix) {
        // La detección de colisiones es POR NIVEL, no global: dos
        // ramas distintas pueden tener la misma clave sin ambigüedad
        // (BODY.A.X y BODY.B.X son nombres distintos).
        Map<String, String> originalByUpper = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : body.entrySet()) {
            String upper = normalizeName(e.getKey());
            String previous = originalByUpper.putIfAbsent(upper, e.getKey());
            if (previous != null) {
                throw new IllegalArgumentException(
                        "Las claves '" + previous + "' y '" + e.getKey()
                        + "' del cuerpo sólo se diferencian por mayúsculas "
                        + "y ambas resolverían a :" + prefix + "." + upper
                        + ". Envía sólo una.");
            }
            String key = prefix + "." + upper;
            Object val = e.getValue();
            if (val instanceof Map<?, ?> nested) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) nested;
                flattenInto(out, nestedMap, key);
            } else {
                out.put(key, val);
            }
        }
    }

    /**
     * V49-bis — version sin aplanar de {@link #flatten} para sub-objetos completos.
     * Cada clave top-level del body se expone con su valor completo (Map, List o
     * escalar) bajo {@code BODY_RAW.NOMBRE}, en MAYÚSCULA, sin recursión.
     *
     * <p>El autor del catálogo lo usa cuando quiere pasar un sub-árbol completo
     * como {@code JSONB} via {@code cast(:BODY_RAW.X as jsonb)}, donde el
     * aplanamiento con puntos pierde el shape del objeto.
     *
     * <p>Detección de colisión por mayúsculas: idéntica a {@link #putAll} y a
     * {@code flattenInto} — la normalización a MAYÚSCULAS puede hacer que dos
     * claves distintas sólo se diferencien por caja y terminen en la misma
     * key. Igual que en los otros métodos, se rechaza en vez de elegir en
     * silencio.
     */
    public static void putRaw(Map<String, Object> target,
                              Map<String, ?> source) {
        if (source == null || source.isEmpty()) return;
        Map<String, String> originalByUpper = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : source.entrySet()) {
            String upper = normalizeName(e.getKey());
            String previous = originalByUpper.putIfAbsent(upper, e.getKey());
            if (previous != null) {
                throw new IllegalArgumentException(
                        "Las claves '" + previous + "' y '" + e.getKey()
                        + "' del cuerpo sólo se diferencian por mayúsculas y "
                        + "ambas resolverían a :" + BODY_RAW + "." + upper
                        + ". Envía sólo una.");
            }
            target.put(BODY_RAW + "." + upper, e.getValue());
        }
    }

    /**
     * V60-bis — Prepara un body del cliente para que el binder JDBC y la
     * validación contra {@code paramTypes} vean la misma identidad
     * sin importar cómo se llamó la key en el JSON.
     *
     * <p>El catálogo siempre declara los placeholders en MAYÚSCULAS
     * ({@code BODY.FECHA}, {@code QUERY.SIZE}). El cliente, en
     * cambio, puede mandar cualquier caja ({@code fecha},
     * {@code BODY.fecha}, {@code Body.Fecha}, …). Hasta ahora
     * case-sensitivity era estricta y rompía silenciosamente —
     * el binder pasaba el valor bajo una key que no estaba en
     * {@code paramTypes}, ningún tipo se validaba, PG recibía un
     * VARCHAR y el cast críptico era la primera señal del
     * problema.
     *
     * <p>Esta función NO muta las keys del body — mantiene el
     * shape literal del cliente (preservando así el matching
     * case-sensitive de Spring JDBC sobre los placeholders del
     * SQL). Devuelve un Map paralelo, indexado por la
     * <b>representación canónica</b> ({@code MAYÚSCULAS +
     * namespace prefix}), que es con la que se indexan las
     * entradas en {@code paramTypes} y el {@code SqlRewriter}.
     *
     * <p>{@link com.co.eurekatic.common.query.ParamBinder} hace
     * el lookup case-insensitive y namespace-aware contra
     * {@code paramTypes}: si el cliente envió {@code "size"} y el
     * catálogo declaró {@code "BODY.SIZE" - "BIGINT"}, el lookup
     * sigue encontrando la entrada. El bind JDBC usa la key
     * original (preservada en {@code values}) para matchear el
     * placeholder del SQL — sea {@code :size} legacy o
     * {@code :BODY.SIZE} moderno.
     *
     * <p>Una key con namespace prefix del cliente
     * ({@code "BODY.fecha"}) se canonicaliza a {@code BODY.FECHA}.
     * Una key con otro prefijo ({@code "QUERY.x"}) se conserva y
     * además se publica su forma canónica para casos donde el
     * catálogo sólo tuvo {@code "QUERY.X"}.
     *
     * <p>Si una key se envía dos veces en cajas distintas y
     * ambas canonicarían al mismo nombre, se rechaza con
     * {@link IllegalArgumentException} — la misma política que
     * {@link #putAll} y {@link #flatten}.
     */
    public static Map<String, Object> indexCanonicalBody(Map<String, ?> body, String namespace) {
        if (body == null || body.isEmpty()) return Map.of();
        Map<String, Object> canonical = new LinkedHashMap<>();
        indexCanonicalBodyInto(canonical, body, namespace, new LinkedHashMap<>());
        return canonical;
    }

    /**
     * Devuelve la key canónica ({@code BODY.X} en MAYÚSCULAS)
     * que se usaría para indexar {@code paramTypes} / el
     * SqlRewriter. Útil cuando el caller (p. ej. {@code QueryService})
     * sólo necesita la transformación de una key suelta, sin
     * recorrer un árbol.
     *
     * <p>Reglas:
     * <ul>
     *   <li>Si la key no tiene punto, antepone el namespace.
     *       {@code "size"} + {@code BODY} → {@code "BODY.SIZE"}.</li>
     *   <li>Si la key ya empieza con un namespace conocido
     *       (cualquiera de {@link #PARAM}, {@link #BODY},
     *       {@link #BODY_RAW}, {@link #QUERY}, {@link #CONTEXT}),
     *       se conserva. {@code "BODY.size"} + {@code BODY} →
     *       {@code "BODY.SIZE"}. {@code "QUERY.size"} + {@code BODY}
     *       → {@code "QUERY.SIZE"} (sin prepender).</li>
     *   <li>Si la key tiene puntos pero empieza con un
     *       segmento desconocido, antepone el namespace.
     *       {@code "x.y"} + {@code BODY} → {@code "BODY.X.Y"}.</li>
     * </ul>
     * La razón de la regla 2: el cliente sabe qué namespace
     * quería (escribió "QUERY.x" cuando quería QUERY) y NO
     * se debe pisar su intención sólo porque el caller
     * pidió indexar en BODY.
     */
    public static String canonicalKeyFor(String rawKey, String namespace) {
        if (rawKey == null || rawKey.isEmpty()) return rawKey;
        if (rawKey.indexOf('.') < 0) {
            return namespace + "." + normalizeName(rawKey);
        }
        String[] segs = rawKey.split("\\.");
        String firstSeg = segs[0];
        if (isKnownNamespace(firstSeg)) {
            // Preserva el namespace del cliente — sólo
            // uppercasar segmentos.
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < segs.length; i++) {
                if (i > 0) sb.append('.');
                sb.append(normalizeName(segs[i]));
            }
            return sb.toString();
        }
        // No es un namespace conocido — prepende el del caller.
        StringBuilder sb = new StringBuilder(namespace);
        for (String seg : segs) {
            sb.append('.').append(normalizeName(seg));
        }
        return sb.toString();
    }

    private static boolean isKnownNamespace(String firstSeg) {
        if (firstSeg == null || firstSeg.isEmpty()) return false;
        String upper = firstSeg.toUpperCase(java.util.Locale.ROOT);
        return PARAM.equals(upper) || BODY.equals(upper)
                || BODY_RAW.equals(upper) || QUERY.equals(upper)
                || CONTEXT.equals(upper);
    }

    private static void indexCanonicalBodyInto(Map<String, Object> canonical,
                                                Map<String, ?> body,
                                                String namespace,
                                                Map<String, String> originalByUpper) {
        for (Map.Entry<String, ?> e : body.entrySet()) {
            String raw = e.getKey();
            String full = canonicalKeyFor(raw, namespace);
            String previous = originalByUpper.putIfAbsent(full, raw);
            if (previous != null) {
                throw new IllegalArgumentException(
                        "Las claves '" + previous + "' y '" + raw
                        + "' del cuerpo sólo se diferencian por mayúsculas "
                        + "y ambas resolverían a :" + full
                        + ". Envía sólo una.");
            }
            Object val = e.getValue();
            if (val instanceof Map<?, ?> nested) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) nested;
                indexCanonicalBodyInto(canonical, nestedMap, full, originalByUpper);
            } else {
                canonical.put(full, val);
            }
        }
    }
}
