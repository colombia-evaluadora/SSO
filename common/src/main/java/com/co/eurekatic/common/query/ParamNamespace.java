package com.co.eurekatic.common.query;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

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
    /** Cuerpo JSON. Lo controla el llamante. */
    public static final String BODY = "BODY";
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
}
