package com.co.eurekatic.common.query;

import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Validación de identificadores SQL (nombres de tabla, esquema y
 * columna) que van a interpolarse en una sentencia.
 *
 * <p><b>Por qué existe.</b> Casi todo el SQL del sistema se construye
 * con parámetros nombrados, y ahí los valores nunca tocan el texto de
 * la sentencia. Pero hay un puñado de sitios donde lo que se interpola
 * es un <em>identificador</em>, no un valor — y un identificador no se
 * puede parametrizar en JDBC. En esos sitios la única defensa posible
 * es comprobar que el identificador tiene forma de identificador.
 *
 * <p><b>De dónde vienen estos identificadores.</b> No del caller HTTP:
 * vienen del catálogo, que solo un administrador puede escribir. Esto
 * no es, por tanto, una barrera contra un usuario anónimo, sino
 * defensa en profundidad: acota el daño de una fila de catálogo
 * corrupta, de un bug en el formulario que la crea, o de un admin con
 * más permisos de los que debería. El propio javadoc de
 * {@code WriteDefinitionRequest} ya prometía esta comprobación
 * ("query-service re-validates it against an identifier regex")
 * mucho antes de que existiera.
 *
 * <p><b>Charset.</b> {@code [A-Za-z_][A-Za-z0-9_]*}, el mismo que ya
 * exigían por su cuenta {@code ArchivoRepository#IDENTIFICADOR},
 * {@code FileReferenceLocationAdminService#IDENTIFICADOR} y
 * {@code fn_validar_tabla_archivo} (V143). Deliberadamente no admite
 * identificadores entrecomillados ({@code "Mi Tabla"}) ni acentos: en
 * este esquema no existen, y aceptarlos obligaría a razonar sobre
 * escapado de comillas, que es justo lo que se quiere evitar.
 *
 * <p><b>Longitud.</b> 63 bytes, el {@code NAMEDATALEN-1} de PostgreSQL.
 * Un identificador más largo lo truncaría el servidor en silencio, y
 * un truncamiento silencioso puede hacer que dos nombres distintos
 * apunten a la misma tabla.
 *
 * <p>TODO: los tres sitios citados arriba siguen con su propia copia
 * del patrón. Consolidarlos aquí es un cambio aparte — tocan
 * file-service y sso-admin, y merecen sus propios tests.
 */
public final class SqlIdentifiers {

    /** Un segmento suelto: nombre de esquema, de tabla o de columna. */
    private static final Pattern SEGMENTO = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    /** {@code NAMEDATALEN - 1} en PostgreSQL. Más allá, el servidor trunca. */
    private static final int MAX_LONGITUD = 63;

    private SqlIdentifiers() {}

    /**
     * Comprueba que {@code identificador} es un identificador SQL
     * simple y lo devuelve tal cual.
     *
     * @param queEs etiqueta para el mensaje de error ("columna",
     *              "nombre de tabla"…)
     * @throws IllegalArgumentException si no lo es
     */
    public static String exigirSimple(String identificador, String queEs) {
        if (identificador == null || identificador.isEmpty()) {
            throw new IllegalArgumentException(queEs + " no puede venir vacío");
        }
        if (identificador.length() > MAX_LONGITUD) {
            throw new IllegalArgumentException(
                    queEs + " '" + identificador + "' excede los "
                            + MAX_LONGITUD + " caracteres que admite PostgreSQL");
        }
        if (!SEGMENTO.matcher(identificador).matches()) {
            throw new IllegalArgumentException(
                    queEs + " '" + identificador + "' no es un identificador SQL válido");
        }
        return identificador;
    }

    /**
     * Comprueba un nombre de tabla, con o sin esquema
     * ({@code tabla} o {@code esquema.tabla}), y lo devuelve tal cual.
     *
     * <p>Se validan los dos segmentos por separado en vez de con un
     * único regex sobre el string entero: así {@code a.b.c} se rechaza
     * por tener tres partes, y no por casualidad de la expresión.
     *
     * @throws IllegalArgumentException si no lo es
     */
    public static String exigirTabla(String nombreTabla, String queEs) {
        if (nombreTabla == null || nombreTabla.isEmpty()) {
            throw new IllegalArgumentException(queEs + " no puede venir vacío");
        }
        String[] partes = nombreTabla.split("\\.", -1);
        if (partes.length > 2) {
            throw new IllegalArgumentException(
                    queEs + " '" + nombreTabla + "' tiene más de un punto; "
                            + "se admite 'tabla' o 'esquema.tabla'");
        }
        for (String parte : partes) {
            exigirSimple(parte, queEs);
        }
        return nombreTabla;
    }

    /** Normaliza a minúsculas con {@link Locale#ROOT} (Postgres pliega así). */
    public static String plegar(String identificador) {
        return identificador.toLowerCase(Locale.ROOT);
    }
}
