package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import java.math.BigInteger;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;
import java.util.stream.Collectors;

/**
 * Tipo escalar de un parametro, tal como lo declara {@code public.query.param_types}
 * (sin el sufijo de obligatoriedad ni los arrays). Cada constante sabe a que tipo JSON
 * se traduce y que valores acepta.
 */
public enum TipoSql {

    ENTERO("integer", null, List.of(), TipoSql::esEnteroValor,
            "BIGINT", "INTEGER", "INT", "SMALLINT"),
    NUMERICO("number", null, List.of(), v -> v instanceof Number,
            "NUMERIC", "DECIMAL"),
    BOOLEANO("boolean", null, List.of(), v -> v instanceof Boolean,
            "BOOLEAN"),
    SI_NO("string", null, List.of("S", "N"), v -> v instanceof String s && (s.equals("S") || s.equals("N")),
            "BOOL_SN"),
    FECHA("string", "date", List.of(), TipoSql::esFecha,
            "DATE"),
    FECHA_HORA("string", "date-time", List.of(), TipoSql::esFechaHora,
            "TIMESTAMP", "TIMESTAMPTZ"),
    HORA("string", "time", List.of(), TipoSql::esHora,
            "TIME"),
    TEXTO("string", null, List.of(), v -> v instanceof String,
            "TEXT", "VARCHAR", "CHAR(1)", "UUID", "STRING",
            "ESTADO_AI", "ESTADO_AC", "ESTADO_ACTIVO_INACTIVO", "NODO_CURRICULAR", "TITULACION_GRADO"),
    /** Un JSONB es objeto o arreglo: las adaptaciones, los materiales o los niveles son listas. */
    OBJETO("object", null, List.of(), v -> v instanceof Map || v instanceof List,
            "JSONB", "JSON");

    private static final Map<String, TipoSql> POR_ALIAS = Arrays.stream(values())
            .flatMap(t -> t.alias.stream().map(a -> Map.entry(a, t)))
            .collect(Collectors.toUnmodifiableMap(Map.Entry::getKey, Map.Entry::getValue));

    private final String jsonType;
    private final String formato;
    private final List<String> valores;
    private final Predicate<Object> acepta;
    private final Set<String> alias;

    TipoSql(String jsonType, String formato, List<String> valores, Predicate<Object> acepta, String... alias) {
        this.jsonType = jsonType;
        this.formato = formato;
        this.valores = valores;
        this.acepta = acepta;
        this.alias = Set.of(alias);
    }

    /**
     * Resuelve el nombre SQL de {@code param_types}. Lanza si no hay traduccion: un tipo
     * desconocido no debe llegar al modelo como texto libre.
     */
    public static TipoSql de(String nombre) {
        TipoSql tipo = POR_ALIAS.get(nombre.trim().toUpperCase(Locale.ROOT));
        if (tipo == null) {
            throw new IllegalArgumentException("tipo de parametro no soportado: " + nombre);
        }
        return tipo;
    }

    public String jsonType() {
        return jsonType;
    }

    /** Formato JSON Schema ({@code date}, {@code date-time}, {@code time}) o {@code null}. */
    public String formato() {
        return formato;
    }

    /** Valores cerrados del tipo; vacio si no es enumerado. */
    public List<String> valores() {
        return valores;
    }

    /** Si el valor, ya deserializado desde JSON, tiene la forma de este tipo. */
    public boolean acepta(Object valor) {
        return acepta.test(valor);
    }

    /** Si el tipo es entero: los ids y los pk de catalogo casi siempre lo son. */
    public boolean esEntero() {
        return this == ENTERO;
    }

    private static boolean esEnteroValor(Object v) {
        if (v instanceof Integer || v instanceof Long || v instanceof Short || v instanceof BigInteger) {
            return true;
        }
        return v instanceof Double d && d == Math.rint(d) && !d.isInfinite();
    }

    private static boolean esFecha(Object v) {
        return v instanceof String s && parsea(() -> LocalDate.parse(s));
    }

    private static boolean esFechaHora(Object v) {
        return v instanceof String s && (parsea(() -> OffsetDateTime.parse(s)) || parsea(() -> LocalDateTime.parse(s)));
    }

    private static boolean esHora(Object v) {
        return v instanceof String s && parsea(() -> LocalTime.parse(s));
    }

    private static boolean parsea(Runnable parser) {
        try {
            parser.run();
            return true;
        } catch (DateTimeParseException e) {
            return false;
        }
    }
}
