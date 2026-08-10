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
            "TEXT", "VARCHAR",
            "BIGINT", "INTEGER", "SMALLINT",
            "NUMERIC",
            "BOOLEAN",
            "DATE", "TIMESTAMP", "TIMESTAMPTZ",
            "UUID", "JSONB", "JSON",
            // Arrays
            "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]"
    );

    /** Tipos array — para que {@code ParamBinder} sepa envolver en {@link java.sql.Array}. */
    public static final Set<String> ARRAY_TYPES = Set.of(
            "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]"
    );

    /**
     * Mapeo del nombre del tipo en el catálogo ({@code "BIGINT"}, {@code "TIMESTAMPTZ"}, ...)
     * a la constante {@link Types} que espera {@code PreparedStatement.setObject(key, value, sqlType)}.
     * Para arrays y tipos que el driver PG maneja como string ({@code JSONB}, {@code JSON},
     * {@code UUID}) usamos {@link Types#OTHER} o {@link Types#ARRAY} según corresponda —
     * el wrapping concreto lo hace {@link ParamBinder}.
     */
    public static final Map<String, Integer> JDBC_TYPES = Map.ofEntries(
            Map.entry("TEXT", Types.VARCHAR),
            Map.entry("VARCHAR", Types.VARCHAR),
            Map.entry("BIGINT", Types.BIGINT),
            Map.entry("INTEGER", Types.INTEGER),
            Map.entry("SMALLINT", Types.SMALLINT),
            Map.entry("NUMERIC", Types.NUMERIC),
            Map.entry("BOOLEAN", Types.BOOLEAN),
            Map.entry("DATE", Types.DATE),
            Map.entry("TIMESTAMP", Types.TIMESTAMP),
            Map.entry("TIMESTAMPTZ", Types.TIMESTAMP_WITH_TIMEZONE),
            Map.entry("UUID", Types.OTHER),
            Map.entry("JSONB", Types.OTHER),
            Map.entry("JSON", Types.OTHER),
            Map.entry("TEXT[]", Types.ARRAY),
            Map.entry("BIGINT[]", Types.ARRAY),
            Map.entry("INTEGER[]", Types.ARRAY),
            Map.entry("NUMERIC[]", Types.ARRAY),
            Map.entry("BOOLEAN[]", Types.ARRAY)
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