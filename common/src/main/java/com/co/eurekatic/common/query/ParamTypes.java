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
     */
    public static final Set<String> ARRAY_TYPES = Set.of(
            "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]",
            "DATE[]", "TIMESTAMP[]", "TIMESTAMPTZ[]"
    );

    /** Tipos numéricos enteros — usados por la guardia runtime para
     *  validar el tipo Java del valor antes de bindear. */
    public static final Set<String> INTEGER_TYPES = Set.of(
            "BIGINT", "INTEGER", "SMALLINT"
    );

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
                "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]",
                "DATE[]", "TIMESTAMP[]", "TIMESTAMPTZ[]"));
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
            Map.entry("TEXT[]", Types.ARRAY),
            Map.entry("BIGINT[]", Types.ARRAY),
            Map.entry("INTEGER[]", Types.ARRAY),
            Map.entry("NUMERIC[]", Types.ARRAY),
            Map.entry("BOOLEAN[]", Types.ARRAY),
            Map.entry("TIME[]", Types.ARRAY),
            Map.entry("DATE[]", Types.ARRAY),
            Map.entry("TIMESTAMP[]", Types.ARRAY),
            Map.entry("TIMESTAMPTZ[]", Types.ARRAY)
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
}