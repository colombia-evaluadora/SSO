package com.co.eurekatic.common.query;

import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Escanea una SQL en busca de placeholders {@code :NAMESPACE.NAME}.
 *
 * <p>Es la fuente única para "qué cuenta como placeholder" y la
 * comparten {@code sso-admin} (validación al guardar) y {@code admin-ui}
 * (auto-poblar la tabla de tipos). El espejo TS vive en
 * {@code admin-ui/src/lib/placeholderScanner.ts}; cualquier cambio
 * aquí debe ir acompañado de un cambio allá.
 *
 * <p>Reconoce los cinco namespaces: {@link ParamNamespace#PARAM},
 * {@link ParamNamespace#BODY}, {@link ParamNamespace#BODY_RAW}
 * (V49-bis, sin aplanar), {@link ParamNamespace#QUERY},
 * {@link ParamNamespace#CONTEXT}. El segmento después del namespace
 * puede tener puntos (cuerpo JSON anidado: {@code :BODY.USER.EMAIL}).
 *
 * <p>El SQL se pasa a mayúsculas antes de la búsqueda — la convención
 * del repo es MAYÚSCULAS ({@link ParamNamespace#isValidName(String)})
 * y aceptar minúsculas invitaría a un segundo estándar.
 */
public final class PlaceholderScanner {

    private PlaceholderScanner() {}

    private static final Pattern P = Pattern.compile(
            ":(PARAM|BODY|BODY_RAW|QUERY|CONTEXT)(\\.[A-Z][A-Z0-9_]*)+");

    /**
     * Devuelve los placeholders únicos en orden de aparición, sin el
     * {@code :} inicial. Nunca devuelve null ni lanza — un SQL sin
     * placeholders produce un set vacío.
     */
    public static Set<String> scan(String sql) {
        if (sql == null || sql.isEmpty()) return Set.of();
        Set<String> out = new LinkedHashSet<>();
        Matcher m = P.matcher(sql.toUpperCase(Locale.ROOT));
        while (m.find()) {
            out.add(m.group().substring(1)); // strip ':'
        }
        return out;
    }
}