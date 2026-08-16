package com.co.eurekatic.common.query;

import java.sql.Types;
import java.util.Map;
import java.util.Set;

/**
 * Set curado de tipos PG/JDBC que el autor del catálogo puede declarar
 * para cada placeholder caller-controlled (ver spec 2026-08-10).
 *
 * <p>Es la fuente única del set: lo importan tanto {@code sso-admin}
 * (para validar y servir el endpoint de la UI) como {@code query-service}
 * (para el bind con {@link java.sql.PreparedStatement#setObject
 * PreparedStatement.setObject}). Si se añade un tipo, cambia en un
 * solo sitio.
 *
 * <p>La forma del lado SQL es un literal en mayúsculas ({@code "TEXT"},
 * {@code "BIGINT[]"}...). El mapeo a {@link Types} se hace por nombre.
 */
public final class ParamTypes {

    private ParamTypes() {}

    /**
     * V49-bis — DOMAIN types del schema {@code academico_test} (definidos en
     * {@code postgres/migrations/V22__academic-schema.sql}). Son los tipos que el
     * autor del catálogo puede asignar a un placeholder cuando la columna destino
     * es un dominio PG con CHECK constraint. El binder genera
     * {@code cast(:PLACEHOLDER as academico_test.DOMAIN)} en el SQL.
     */
    public static final Set<String> DOMAIN_TYPES = Set.of(
            "BOOL_SN",
            "ESTADO_AI",
            "ESTADO_AC",
            "ESTADO_ACTIVO_INACTIVO",
            "NODO_CURRICULAR",
            "TITULACION_GRADO"
    );

    /**
     * Tipos array — para que {@code ParamBinder} sepa envolver en {@link java.sql.Array}.
     *
     * <p>V61 — se suman {@code DATE[]}, {@code TIMESTAMP[]} y
     * {@code TIMESTAMPTZ[]}. Antes sólo {@code TIME[]} tenía
     * contraparte array entre los tipos temporales — un autor
     * que quisiera {@code WHERE fecha = ANY(:BODY.FECHAS)} no
     * tenía forma de declarar el tipo y caía al auto-derive de
     * Spring (rompe con listas, ver spec 2026-08-10).
     *
     * <p>V61-bis — se suma {@code JSONB[]}: lista de objetos JSON
     * (p. ej. {@code [{"k":"v"},{"k":"w"}]}). A diferencia de
     * {@code JSONB} escalar (que sólo se usa vía {@code BODY_RAW.X}),
     * el elemento de un {@code JSONB[]} puede venir como sub-objeto
     * (Map) o como literal ya serializado (String) — ver
     * {@code ParamBinder.toPgArray}.
     */
    public static final Set<String> ARRAY_TYPES = Set.of(
            "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]",
            "DATE[]", "TIMESTAMP[]", "TIMESTAMPTZ[]", "JSONB[]"
    );

    /** Tipos numéricos enteros — usados por la guardia runtime para
     *  validar el tipo Java del valor antes de bindear.
     *
     *  <p>{@code FILE} entra en este set a propósito, no por
     *  descuido: ver el javadoc de {@link #FILE}. Para cuando el
     *  valor llega a {@code ParamBinder} ya es un {@code Long}
     *  (el {@code pk_tarchivo} que file-service sustituyó en el
     *  campo), así que la guardia debe tratarlo exactamente igual
     *  que un {@code BIGINT} — mismo mensaje de error si alguien
     *  manda otra cosa. */
    public static final Set<String> INTEGER_TYPES = Set.of(
            "BIGINT", "INTEGER", "SMALLINT", "FILE"
    );

    /**
     * Marca un placeholder como "este parámetro es un archivo": el
     * cliente lo manda como parte binaria de un {@code multipart},
     * no como campo JSON. {@code file-service} lo intercepta antes
     * de reenviar al catálogo — sube el binario a S3, reserva la
     * fila en {@code TARCHIVO}, y sustituye el campo por su
     * {@code pk_tarchivo} (un {@code Long}). Por eso, en TODOS los
     * puntos de este archivo donde importa el tipo real de bind
     * (guardia de {@code ParamBinder}, {@link #JDBC_TYPES}, cast en
     * {@link #PG_CAST_NAME}), {@code FILE} se comporta exactamente
     * como {@code BIGINT} — la diferencia sólo le importa a
     * {@code file-service}, que usa esta declaración para saber
     * QUÉ campos del multipart debe aceptar como archivo para una
     * ruta dada (ver {@code FileDestinationAccessService}) y
     * rechazar cualquier otro. Un placeholder declarado {@code FILE}
     * que además use {@link #REQUIRED_SUFFIX} ({@code "FILE!"})
     * exige que el archivo venga sí o sí.
     *
     * <p>No hay {@code FILE[]} todavía — un campo con varios
     * ficheros ({@code TransformadorMultipart} ya soporta "varios
     * → lista de ids") no tiene aún forma de declararse en el
     * catálogo. Se añade cuando haga falta, igual que el resto de
     * los tipos array.
     */
    public static final String FILE = "FILE";

    /** Tipos numéricos con decimales. */
    public static final Set<String> DECIMAL_TYPES = Set.of(
            "NUMERIC"
    );

    /** Tipos textuales — para validación laxa (cualquier String pasa). */
    public static final Set<String> STRING_TYPES = Set.of(
            "TEXT", "VARCHAR", "CHAR(1)"
    );

    /** Tipos temporales — Jackson entrega String ISO-8601 o
     *  {@code java.time.*}; PG aplica el cast. */
    public static final Set<String> TEMPORAL_TYPES = Set.of(
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ"
    );

    /**
     * Set curado que se ofrece en el dropdown de la UI y que
     * el sso-admin acepta al validar un {@code paramTypes}.
     * Combina escalares built-in, arrays built-in y los
     * DOMAIN types del schema {@code academico_test} — un
     * único set compartido por la UI y el binder.
     *
     * <p>Cada vez que se añade un tipo nuevo al catálogo
     * (escalares, arrays o DOMAIN), basta con actualizar
     * los sets arriba — el set curado se reconstruye al
     * cargar la clase, sin necesidad de tocar este método.
     */
    public static final Set<String> CURATED;
    static {
        java.util.LinkedHashSet<String> curated = new java.util.LinkedHashSet<>();
        curated.addAll(Set.of(
                "TEXT", "VARCHAR", "CHAR(1)",
                "BIGINT", "INTEGER", "SMALLINT",
                "NUMERIC",
                "BOOLEAN",
                "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
                "UUID", "JSONB", "JSON",
                FILE,
                "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]",
                "DATE[]", "TIMESTAMP[]", "TIMESTAMPTZ[]", "JSONB[]"));
        curated.addAll(DOMAIN_TYPES);
        CURATED = java.util.Collections.unmodifiableSet(curated);
    }

    /**
     * V49-bis — mapeo del nombre del set curado al nombre PG-cast (lo que va
     * dentro de {@code cast(:var as X)}). Los tipos built-in van sin schema prefix;
     * los DOMAIN types del academico van con {@code academico_test.} porque el
     * {@code search_path} por defecto no incluye ese schema.
     *
     * <p>Esto lo consume {@link SqlRewriter} para construir el SQL con casts.
     * El binder llama al rewriter con {@code def.paramTypes()} y este map.
     */
    public static final Map<String, String> PG_CAST_NAME = Map.ofEntries(
            // Escalares built-in
            Map.entry("TEXT", "text"),
            Map.entry("VARCHAR", "varchar"),
            Map.entry("CHAR(1)", "char"),
            Map.entry("BIGINT", "bigint"),
            Map.entry("INTEGER", "integer"),
            Map.entry("SMALLINT", "smallint"),
            Map.entry("NUMERIC", "numeric"),
            Map.entry("BOOLEAN", "boolean"),
            Map.entry("DATE", "date"),
            Map.entry("TIME", "time"),
            Map.entry("TIMESTAMP", "timestamp"),
            Map.entry("TIMESTAMPTZ", "timestamptz"),
            Map.entry("UUID", "uuid"),
            Map.entry("JSONB", "jsonb"),
            Map.entry("JSON", "json"),
            // FILE ya llegó a ParamBinder como el Long que
            // file-service sustituyó — mismo cast que BIGINT.
            Map.entry("FILE", "bigint"),
            // Arrays built-in
            Map.entry("TEXT[]", "text[]"),
            Map.entry("BIGINT[]", "int8[]"),
            Map.entry("INTEGER[]", "int4[]"),
            Map.entry("NUMERIC[]", "numeric[]"),
            Map.entry("BOOLEAN[]", "bool[]"),
            Map.entry("TIME[]", "time[]"),
            Map.entry("DATE[]", "date[]"),
            Map.entry("TIMESTAMP[]", "timestamp[]"),
            Map.entry("TIMESTAMPTZ[]", "timestamptz[]"),
            Map.entry("JSONB[]", "jsonb[]"),
            // DOMAIN types — schema-qualified
            Map.entry("BOOL_SN",                "academico_test.bool_sn"),
            Map.entry("ESTADO_AI",              "academico_test.estado_ai"),
            Map.entry("ESTADO_AC",              "academico_test.estado_ac"),
            Map.entry("ESTADO_ACTIVO_INACTIVO", "academico_test.estado_activo_inactivo"),
            Map.entry("NODO_CURRICULAR",        "academico_test.nodo_curricular"),
            Map.entry("TITULACION_GRADO",       "academico_test.titulacion_grado")
    );

    /**
     * Mapeo del nombre del tipo en el catálogo ({@code "BIGINT"}, {@code "TIMESTAMPTZ"}, ...)
     * a la constante {@link Types} que espera {@code PreparedStatement.setObject(key, value, sqlType)}.
     * Para arrays y tipos que el driver PG maneja como string ({@code JSONB}, {@code JSON},
     * {@code UUID}) usamos {@link Types#OTHER} o {@link Types#ARRAY} según corresponda —
     * el wrapping concreto lo hace {@link ParamBinder} (callable path).
     *
     * <p>V49-bis: este map ya NO lo usa el camino normal de {@link ParamBinder} — el
     * cast se hace en SQL via {@link SqlRewriter}. Se conserva para
     * {@code QueryService.executeCallable} (CallableStatement requiere sqlType
     * explícito para OUT params) y como documentación de la correspondencia
     * nombre-PG → {@link Types}.
     */
    public static final Map<String, Integer> JDBC_TYPES = Map.ofEntries(
            Map.entry("TEXT", Types.VARCHAR),
            Map.entry("VARCHAR", Types.VARCHAR),
            Map.entry("CHAR(1)", Types.CHAR),
            Map.entry("BIGINT", Types.BIGINT),
            Map.entry("INTEGER", Types.INTEGER),
            Map.entry("SMALLINT", Types.SMALLINT),
            Map.entry("NUMERIC", Types.NUMERIC),
            Map.entry("BOOLEAN", Types.BOOLEAN),
            Map.entry("DATE", Types.DATE),
            Map.entry("TIME", Types.TIME),
            Map.entry("TIMESTAMP", Types.TIMESTAMP),
            Map.entry("TIMESTAMPTZ", Types.TIMESTAMP_WITH_TIMEZONE),
            Map.entry("UUID", Types.OTHER),
            Map.entry("JSONB", Types.OTHER),
            Map.entry("JSON", Types.OTHER),
            Map.entry("FILE", Types.BIGINT),
            Map.entry("TEXT[]", Types.ARRAY),
            Map.entry("BIGINT[]", Types.ARRAY),
            Map.entry("INTEGER[]", Types.ARRAY),
            Map.entry("NUMERIC[]", Types.ARRAY),
            Map.entry("BOOLEAN[]", Types.ARRAY),
            Map.entry("TIME[]", Types.ARRAY),
            Map.entry("DATE[]", Types.ARRAY),
            Map.entry("TIMESTAMP[]", Types.ARRAY),
            Map.entry("TIMESTAMPTZ[]", Types.ARRAY),
            Map.entry("JSONB[]", Types.ARRAY)
    );

    /**
     * ¿Es {@code key} un nombre completo válido para una entrada de
     * {@code PARAM_TYPES}? Un placeholder es {@code BODY.USER.EMAIL},
     * varios segmentos separados por punto, cada uno un nombre válido
     * según {@link ParamNamespace#isValidName(String)}.
     *
     * <p>Reutiliza la misma regla que las variables de ruta para
     * evitar divergencias.
     */
    public static boolean isValidKey(String key) {
        if (key == null || key.isEmpty()) return false;
        for (String segment : key.split("\\.")) {
            if (!ParamNamespace.isValidName(segment)) return false;
        }
        return true;
    }

    /**
     * V62 — sufijo que marca un parámetro como obligatorio
     * ({@code "BIGINT!"}). Constante única para que
     * {@link #parseDeclaration}, la validación de {@code sso-admin}
     * al guardar y la respuesta de {@code GET /query/param-types}
     * (que se lo expone al admin-ui) lean el mismo literal.
     */
    public static final String REQUIRED_SUFFIX = "!";

    /**
     * V63 — separador entre {@link #FILE} y la clasificación
     * opcional que sigue ({@code "FILE:perfilUsuario"}). Ver
     * {@link #parseDeclaration} y {@link #isValidFileClassification}.
     * Sólo tiene efecto cuando el tipo base es exactamente
     * {@code FILE} — {@code "BIGINT:algo"} no es una sintaxis válida
     * para ningún otro tipo, y {@link #parseDeclaration} lo deja tal
     * cual (fallará después en {@code CURATED.contains(...)}, con un
     * mensaje de "tipo no soportado" en vez de uno específico de
     * clasificación — es un tipo mal escrito, no una clasificación
     * mal escrita).
     */
    public static final String FILE_CLASSIFICATION_SEPARATOR = ":";

    private static final java.util.regex.Pattern FILE_CLASSIFICATION_PATTERN =
            java.util.regex.Pattern.compile("[A-Za-z][A-Za-z0-9_]*");

    /**
     * ¿Es {@code clasificacion} un nombre válido para usar como
     * carpeta de S3 ({@code <clasificacion>/<pk>.<extensión>})? Letra
     * inicial, luego letras/dígitos/guion bajo — deliberadamente
     * permisivo en mayúsculas (a diferencia de
     * {@link ParamNamespace#isValidName}, que exige TODO mayúscula):
     * la clasificación se vuelve un segmento de ruta S3 literal, y el
     * vocabulario histórico de {@code TARCHIVO.etiqueta} es camelCase
     * ({@code perfilUsuario}, {@code firmaMecanica}) — forzar
     * mayúsculas rompería esa convención en vez de mantenerla.
     */
    public static boolean isValidFileClassification(String clasificacion) {
        return clasificacion != null && FILE_CLASSIFICATION_PATTERN.matcher(clasificacion).matches();
    }

    /**
     * V65 — clasificaciones conocidas de {@code TARCHIVO.etiqueta}
     * que además de un valor libre válido para
     * {@link #isValidFileClassification} corresponden a un patrón de
     * ruta S3 histórico real (revisado en la BD de producción, filas
     * {@code created_by = 'migracion'}). Se expone vía
     * {@code GET /query/param-types} como catálogo sugerido para el
     * admin-ui — NO es una lista cerrada: {@link #isValidFileClassification}
     * sigue aceptando cualquier valor con forma válida, para no
     * bloquear una clasificación nueva que aún no esté aquí.
     *
     * <p>Deliberadamente afuera:
     * <ul>
     *   <li>{@code firmaMecanica} — {@code TARCHIVO.urls3} siempre
     *       vacío en las filas migradas; no hay objeto S3 real detrás
     *       de esa etiqueta.</li>
     *   <li>{@code informeFinal}, {@code certificacion},
     *       {@code informePeriodo} — reportes PDF con una carpeta más
     *       de profundidad ({@code PA<año>[/<periodo>]}) que este
     *       esquema de un solo {@link #FILE_ESTABLISHMENT_SEPARATOR}
     *       no modela; probablemente generados por un proceso batch
     *       aparte, no por una subida de usuario vía
     *       {@code FILE:clasificacion}.</li>
     * </ul>
     */
    public static final Set<String> KNOWN_FILE_CLASSIFICATIONS = Set.of(
            "perfilUsuario", "actividad", "recursoCompartido", "matricula", "candidato", "escudo"
    );

    /**
     * V65 — clasificaciones cuyo layout histórico en S3 lleva el
     * código de establecimiento como segundo segmento de ruta
     * ({@code <sitio>/<establecimiento.codigo>/<clasificacion>/...}),
     * a diferencia de {@code perfilUsuario} que no lo lleva. Sólo
     * tiene efecto informativo/documental — la validación real de
     * "¿esta clasificación exige el tercer componente
     * {@code :campoEstablecimiento}?" no se hace aquí: un autor puede
     * declarar el campo de establecimiento en cualquier clasificación
     * (incluida una que no esté en {@link #KNOWN_FILE_CLASSIFICATIONS}),
     * y omitirlo en una que normalmente lo llevaría — el catálogo no
     * fuerza la relación, sólo la permite.
     */
    public static final Set<String> ESTABLISHMENT_SCOPED_FILE_CLASSIFICATIONS = Set.of(
            "actividad", "recursoCompartido", "matricula", "candidato", "escudo"
    );

    private static final java.util.regex.Pattern FILE_ESTABLISHMENT_FIELD_PATTERN =
            java.util.regex.Pattern.compile("[A-Za-z][A-Za-z0-9_]*");

    /**
     * V65 — separador entre la clasificación y el nombre del campo
     * de texto del multipart que trae el código de establecimiento
     * ({@code "FILE:actividad:idEstablecimiento"}). Mismo carácter
     * que {@link #FILE_CLASSIFICATION_SEPARATOR} — un tercer
     * componente, no un separador nuevo — porque la clasificación ya
     * prohíbe {@code ':'} en su propio patrón
     * ({@link #FILE_CLASSIFICATION_PATTERN}), así que partir por la
     * PRIMERA ocurrencia después del prefijo {@code FILE:} es
     * inambiguo.
     */
    public static final String FILE_ESTABLISHMENT_SEPARATOR = FILE_CLASSIFICATION_SEPARATOR;

    /**
     * ¿Es {@code campo} un nombre válido para referenciar OTRO campo
     * de texto del mismo multipart ({@code FILE:actividad:<campo>})?
     * Mismo patrón que {@link #isValidFileClassification} — es,
     * igual que la clasificación, un identificador elegido por quien
     * arma el multipart, no un placeholder {@code :BODY.X} del SQL
     * (ver {@code ReenvioController#canonicoDe}: ese campo se busca
     * por nombre EXACTO en los campos de texto del multipart, no por
     * clave canónica).
     */
    public static boolean isValidFileEstablishmentField(String campo) {
        return campo != null && FILE_ESTABLISHMENT_FIELD_PATTERN.matcher(campo).matches();
    }

    /**
     * V62 — el tipo declarado más el sufijo opcional de
     * obligatoriedad ({@code baseType} sin el {@code '!'}, más
     * {@code nullable}).
     *
     * <p>V63 — {@code fileClassification} sólo se llena cuando
     * {@code baseType} es {@link #FILE} y el autor agregó
     * {@code :clasificacion} ({@code "FILE:perfilUsuario"},
     * {@code "FILE:perfilUsuario!"}). {@code null} para todo lo
     * demás, incluido un {@code FILE} sin clasificar — ese caso
     * sigue siendo válido y usa el formato de clave de siempre
     * ({@code <pk>/<nombre>}), ver {@code TransformadorMultipart}.
     *
     * <p>V65 — {@code fileEstablishmentField} sólo se llena cuando
     * ADEMÁS de la clasificación el autor agregó un tercer componente
     * ({@code "FILE:actividad:idEstablecimiento"}): el nombre del
     * campo de texto del multipart que trae el código de
     * establecimiento a anteponer en la ruta S3. {@code null} si no
     * se declaró — la clasificación sigue funcionando sin él, sin
     * segmento de establecimiento (igual que antes de V65).
     */
    public record Declaration(String baseType, boolean nullable, String fileClassification,
                              String fileEstablishmentField) {}

    /**
     * Parsea un tipo declarado en el catálogo: el sufijo de
     * nulabilidad ({@code '!'}) y, si el tipo base es {@link #FILE},
     * la clasificación opcional ({@code ':clasificacion'}) y el
     * campo de establecimiento opcional ({@code ':campo'}).
     *
     * <p><b>Nulabilidad</b> — por defecto, TODO parámetro es
     * <b>nullable</b>: un cliente que manda {@code null} explícito,
     * o que directamente omite el campo, bindea {@code NULL} de SQL
     * en vez de reventar (antes de V62 ambos casos dejaban el
     * placeholder sin valor y Spring fallaba con un {@code 500}
     * opaco antes de llegar siquiera a Postgres — ver
     * {@code ParamBinder.buildStrict}). Un autor marca un parámetro
     * como <b>obligatorio</b> añadiendo {@code '!'} al final del
     * tipo: {@code "BIGINT!"}, {@code "FILE!"}, {@code "BIGINT[]!"}.
     * Enviarlo como {@code null} u omitirlo entonces responde
     * {@code 400} nombrando el parámetro. Ningún tipo del set
     * {@link #CURATED} termina en {@code '!'}, así que el sufijo
     * nunca colisiona con un nombre de tipo real.
     *
     * <p><b>Clasificación (V63)</b> — {@code "FILE:perfilUsuario"}
     * declara, además de "este placeholder es un archivo", CON QUÉ
     * NOMBRE de carpeta S3 se organiza — {@code file-service} arma
     * la clave como {@code <clasificacion>/<pk_tarchivo>.<extensión>}
     * en vez del {@code <pk_tarchivo>/<nombre-original>} genérico,
     * imitando el layout que ya usaban las filas históricas migradas
     * ({@code .../perfilUsuario/141906.jpeg}).
     *
     * <p><b>Campo de establecimiento (V65)</b> —
     * {@code "FILE:actividad:idEstablecimiento"} agrega un TERCER
     * componente: el nombre de OTRO campo de texto del mismo
     * multipart cuyo valor {@code file-service} valida contra
     * {@code testablecimiento.codigo} y antepone a la clasificación
     * ({@code <sitio>/<código>/<clasificacion>/<pk>.<extensión>}),
     * imitando el layout histórico de las clasificaciones que sí
     * llevan establecimiento ({@code .../120001003751/actividad/...}
     * — ver {@link #ESTABLISHMENT_SCOPED_FILE_CLASSIFICATIONS}). El
     * orden final de los tres componentes es
     * {@code TIPO[:clasificacion[:campoEstablecimiento]][!]} — el
     * sufijo de obligatoriedad siempre al final.
     *
     * @param raw el valor tal cual está en {@code paramTypes} (p.ej.
     *            {@code "FILE:actividad:idEstablecimiento!"}); puede
     *            ser {@code null}.
     */
    public static Declaration parseDeclaration(String raw) {
        if (raw == null) return new Declaration(null, true, null, null);
        String trimmed = raw.trim();
        boolean required = trimmed.endsWith(REQUIRED_SUFFIX);
        String sinSufijoObligatorio = required
                ? trimmed.substring(0, trimmed.length() - REQUIRED_SUFFIX.length())
                : trimmed;

        String prefijoFile = FILE + FILE_CLASSIFICATION_SEPARATOR;
        if (sinSufijoObligatorio.startsWith(prefijoFile)) {
            String resto = sinSufijoObligatorio.substring(prefijoFile.length());
            int separador = resto.indexOf(FILE_ESTABLISHMENT_SEPARATOR);
            String clasificacion = separador < 0 ? resto : resto.substring(0, separador);
            String campoEstablecimiento = separador < 0 ? null : resto.substring(separador + 1);
            return new Declaration(FILE, !required,
                    clasificacion.isEmpty() ? null : clasificacion,
                    campoEstablecimiento == null || campoEstablecimiento.isEmpty() ? null : campoEstablecimiento);
        }
        return new Declaration(sinSufijoObligatorio, !required, null, null);
    }
}