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

    /** Set curado que se ofrece en el dropdown de la UI. */
    public static final Set<String> CURATED = Set.of(
            // Escalares
            "TEXT", "VARCHAR", "CHAR(1)",
            "BIGINT", "INTEGER", "SMALLINT",
            "NUMERIC",
            "BOOLEAN",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
            "UUID", "JSONB", "JSON",
            // Arrays
            "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]"
    );

    /** Tipos array — para que {@code ParamBinder} sepa envolver en {@link java.sql.Array}. */
    public static final Set<String> ARRAY_TYPES = Set.of(
            "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]"
    );

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
            Map.entry("TIME[]", Types.ARRAY)
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