package com.co.eurekatic.common.error;

import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;

import java.sql.SQLException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Deque;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Convierte un {@link SQLException} en un error apto para cruzar el cable:
 * clasificado por {@link SqlErrorKind} y con el mensaje depurado de todo
 * identificador físico de la base de datos.
 *
 * <p>Dos decisiones sostienen el resto:
 *
 * <p><b>1. Se leen los campos estructurados, no {@code getMessage()}.</b>
 * {@code SQLException.getMessage()} entrega MESSAGE, DETAIL y HINT ya
 * concatenados; el DETAIL de una {@code unique_violation} contiene los valores
 * reales que colisionaron ({@code Key (correo)=(alguien@dominio) already
 * exists}), así que reenviarlo publica el dato de un tercero. El driver ya trae
 * los campos separados en {@link ServerErrorMessage}: se usa sólo MESSAGE.
 *
 * <p><b>2. El SQLState no basta para decidir si el mensaje es reenviable.</b>
 * Las funciones del esquema levantan {@code RAISE EXCEPTION ... USING ERRCODE =
 * '23503'} con texto de negocio redactado a mano, indistinguible por código de
 * la violación de FK que emite el motor. El discriminador es que el motor
 * puebla {@code constraint}/{@code table} en la respuesta y {@code RAISE} no:
 * lo que viene del motor se reemplaza por un texto genérico, lo que viene del
 * autor se conserva y se le redactan los identificadores.
 *
 * <p><b>3. "Genérico" no es lo mismo que "sin pistas".</b> Cuando lo que
 * falló es literalmente el dato que el llamante mandó en el body/param
 * (falta un campo, o el valor no tiene el tipo/formato esperado), el
 * genérico se enriquece con el nombre del campo o el tipo — nunca con el
 * valor — porque eso es exactamente lo que el cliente de query-service
 * necesita para corregir la petición, y ni el nombre de un campo ni un
 * tipo SQL builtin ({@code bigint}, {@code character varying(130)})
 * identifican tabla o constraint.
 */
public final class SqlErrorSanitizer {

    private SqlErrorSanitizer() {}

    /** Resultado ya apto para publicar en una respuesta HTTP. */
    public record Sanitized(SqlErrorKind kind, String sqlState, String message) {

        public String code() {
            return kind.code();
        }
    }

    private static final int MAX_LENGTH = 300;

    /** Nombres físicos legados que aparecen literalmente en los mensajes. */
    private static final Map<String, String> TABLE_TERMS = new LinkedHashMap<>();

    static {
        TABLE_TERMS.put("TSEDE_USUARIO", "asignación de usuario a sede");
        TABLE_TERMS.put("TPROPIEDAD_JURIDICA", "propiedad jurídica");
        TABLE_TERMS.put("TESTABLECIMIENTO", "establecimiento");
        TABLE_TERMS.put("TDISCAPACIDAD", "discapacidad");
        TABLE_TERMS.put("TDENOMINACION", "denominación");
        TABLE_TERMS.put("TLISTA_VALOR", "catálogo");
        TABLE_TERMS.put("TFUNCIONARIO", "funcionario");
        TABLE_TERMS.put("TMUNICIPIO", "municipio");
        TABLE_TERMS.put("TUSUARIO", "usuario");
        TABLE_TERMS.put("TARCHIVO", "archivo");
        TABLE_TERMS.put("TMENU", "menú");
        TABLE_TERMS.put("TSEDE", "sede");
        TABLE_TERMS.put("TPLAN", "plan");
        TABLE_TERMS.put("TROL", "rol");
    }

    private static final Pattern SCHEMA_PREFIX =
            Pattern.compile("\\b(?:academico_test|academico|public|sso)\\.", Pattern.CASE_INSENSITIVE);

    /** {@code FK_TLV_ZONA} / {@code PK_TSEDE} / {@code PK_ESTABLECIMIENTO}. */
    private static final Pattern KEY_COLUMN =
            Pattern.compile("\\b(?:FK|PK)_(?:TLV_|T)?([A-Z][A-Z0-9_]*)\\b");

    private static final Pattern TABLE_TOKEN =
            Pattern.compile("\\b(" + String.join("|", TABLE_TERMS.keySet()) + ")\\b");

    /** Red de seguridad para tablas {@code T*} que aún no están en el diccionario. */
    private static final Pattern RESIDUAL_TABLE =
            Pattern.compile("\\bT[A-Z]{4,}(?:_[A-Z0-9]+)*\\b");

    /** Prefijo {@code fn_algo: } con el que las funciones etiquetan sus mensajes. */
    private static final Pattern ROUTINE_PREFIX =
            Pattern.compile("^[a-z_][a-z0-9_]*\\s*:\\s*");

    private static final Pattern SEVERITY_PREFIX =
            Pattern.compile("^(?:ERROR|FATAL|PANIC)\\s*:\\s*", Pattern.CASE_INSENSITIVE);

    /** Marcadores de violación emitida por el motor, para el camino sin driver PG. */
    private static final Pattern ENGINE_MARKERS = Pattern.compile(
            "violates (?:unique|foreign key|not-null|check) constraint"
                    + "|duplicate key value"
                    + "|null value in column"
                    + "|llave duplicada viola restricción",
            Pattern.CASE_INSENSITIVE);

    /**
     * {@code Key (col1, col2)=(...)} — el DETAIL de una violación de unicidad
     * o de FK. Sólo se toma la lista de columnas antes del {@code =}; lo que
     * sigue son los valores reales que colisionaron y nunca se lee.
     */
    private static final Pattern DETAIL_COLUMNS = Pattern.compile("Key \\(([^)]+)\\)=");

    private static final Pattern DETAIL_LINE = Pattern.compile("Detail:\\s*(.+)");

    /**
     * {@code invalid input syntax for type bigint: "abc"} / {@code value too
     * long for type character varying(130)}. Se corta antes de los dos
     * puntos para no arrastrar el valor entre comillas que sigue en el
     * primer caso.
     */
    private static final Pattern NATIVE_TYPE =
            Pattern.compile("for type ([a-zA-Z][a-zA-Z0-9_ ]*(?:\\([0-9, ]+\\))?)");

    /**
     * Clasifica y depura. Recorre la cadena ({@code getNextException} y
     * {@code getCause}) hasta el primer eslabón con SQLState reconocible.
     */
    public static Sanitized sanitize(SQLException ex) {
        for (SQLException cur : chain(ex)) {
            String state = cur.getSQLState();
            if (state == null || state.length() < 2) {
                continue;
            }
            return new Sanitized(kindOf(state), state, messageFor(cur, state, kindOf(state)));
        }
        return new Sanitized(SqlErrorKind.INTERNAL, null, SqlErrorKind.INTERNAL.defaultMessage());
    }

    static SqlErrorKind kindOf(String sqlState) {
        return switch (sqlState) {
            case "P0002" -> SqlErrorKind.NOT_FOUND;
            case "42501" -> SqlErrorKind.PERMISSION_DENIED;
            case "23505" -> SqlErrorKind.DUPLICATE;
            case "23502" -> SqlErrorKind.MISSING_REQUIRED;
            case "23503" -> SqlErrorKind.REFERENCE_MISSING;
            case "P0001" -> SqlErrorKind.BUSINESS_RULE;
            default -> switch (sqlState.substring(0, 2)) {
                case "22" -> SqlErrorKind.INVALID_VALUE;
                case "23" -> SqlErrorKind.CONFLICT;
                case "08", "40", "53", "57" -> SqlErrorKind.UNAVAILABLE;
                default -> SqlErrorKind.INTERNAL;
            };
        };
    }

    /**
     * SQLState de clase 22 (data_exception) que el propio esquema adopta como
     * convención para sus {@code RAISE EXCEPTION} de negocio — ver
     * {@code grep -rhoE "ERRCODE = '2[0-9]{4}'" postgres/migrations/*.sql},
     * que no devuelve ningún otro código de esa clase. Cualquier otro 22xxx
     * ({@code 22001} truncamiento, {@code 22P02} cast inválido, {@code 22012}
     * división por cero, …) sólo lo puede emitir el motor: nadie en el
     * esquema los levanta a mano.
     */
    private static final String BUSINESS_DATA_EXCEPTION_STATE = "22023";

    /**
     * Texto público. El mensaje del autor sobrevive redactado; el del motor y
     * cualquier fallo de sintaxis u objeto inexistente se reemplazan por uno
     * genérico — ahí el texto original sólo nombra tablas, columnas y
     * constraints reales. La única excepción deliberada: cuando el motor
     * rechaza el dato en sí (falta un campo, sobra, no tiene el tipo o
     * formato esperado), el genérico se enriquece con el nombre del campo o
     * el tipo esperado — nunca con el valor que el cliente envió — porque
     * ahí sí es lo que el llamante necesita para corregir su body/param.
     */
    private static String messageFor(SQLException ex, String sqlState, SqlErrorKind kind) {
        if (kind == SqlErrorKind.INTERNAL || kind == SqlErrorKind.UNAVAILABLE) {
            return kind.defaultMessage();
        }
        if (sqlState.startsWith("22") && !BUSINESS_DATA_EXCEPTION_STATE.equals(sqlState)) {
            return withTypeHint(kind.defaultMessage(), authorMessage(ex));
        }
        String raw = authorMessage(ex);
        if (raw == null) {
            return kind.defaultMessage();
        }
        if (engineGenerated(ex, raw)) {
            return withFieldHint(kind, ex);
        }
        String redacted = redact(raw);
        return redacted.isBlank() ? kind.defaultMessage() : truncate(redacted);
    }

    /**
     * Añade el tipo PG esperado ({@code bigint}, {@code character
     * varying(130)}, …) cuando el mensaje nativo lo trae. El nombre de un
     * tipo SQL no identifica tabla ni columna — es vocabulario del motor,
     * no del esquema — así que es seguro reenviarlo.
     */
    private static String withTypeHint(String base, String rawMessage) {
        if (rawMessage == null) {
            return base;
        }
        Matcher m = NATIVE_TYPE.matcher(rawMessage);
        return m.find() ? base + " (tipo esperado: " + m.group(1).trim() + ")" : base;
    }

    /**
     * Añade el/los campo(s) que el motor rechazó — vía {@code getColumn()}
     * cuando el driver lo puebla ({@code not_null_violation}) o, si no,
     * parseando sólo la lista de columnas del DETAIL ({@code Key (col)=},
     * {@code unique_violation}/{@code foreign_key_violation}) sin tocar los
     * valores que le siguen al {@code =}.
     */
    private static String withFieldHint(SqlErrorKind kind, SQLException ex) {
        String field = fieldName(ex);
        if (field == null) {
            return kind.defaultMessage();
        }
        return switch (kind) {
            case MISSING_REQUIRED -> "Falta el campo obligatorio '" + field + "'";
            case REFERENCE_MISSING -> "La referencia del campo '" + field + "' no existe o no está activa";
            case DUPLICATE -> "Ya existe un registro con el mismo valor en '" + field + "'";
            default -> kind.defaultMessage() + " (campo: " + field + ")";
        };
    }

    private static String fieldName(SQLException ex) {
        ServerErrorMessage sem = serverError(ex);
        if (sem != null && sem.getColumn() != null && !sem.getColumn().isBlank()) {
            return humanizeFieldName(sem.getColumn());
        }
        String detail = sem != null ? sem.getDetail() : detailLine(ex.getMessage());
        if (detail == null) {
            return null;
        }
        Matcher m = DETAIL_COLUMNS.matcher(detail);
        if (!m.find()) {
            return null;
        }
        return java.util.Arrays.stream(m.group(1).split(",\\s*"))
                .map(SqlErrorSanitizer::humanizeFieldName)
                .collect(java.util.stream.Collectors.joining(", "));
    }

    private static String detailLine(String raw) {
        if (raw == null) {
            return null;
        }
        Matcher m = DETAIL_LINE.matcher(raw);
        return m.find() ? m.group(1) : null;
    }

    /** {@code fk_tlv_estado} → {@code estado}; reusa el mismo diccionario que {@link #redact}. */
    private static String humanizeFieldName(String rawColumn) {
        return redact(rawColumn.toUpperCase(Locale.ROOT)).toLowerCase(Locale.ROOT).replace('_', ' ');
    }

    /**
     * El campo MESSAGE aislado. Sin driver PG a mano se corta en el primer salto
     * de línea, que es donde el servidor arranca {@code Detail:} y {@code Hint:}.
     */
    private static String authorMessage(SQLException ex) {
        ServerErrorMessage sem = serverError(ex);
        String raw = sem != null ? sem.getMessage() : ex.getMessage();
        if (raw == null) {
            return null;
        }
        int nl = raw.indexOf('\n');
        return SEVERITY_PREFIX.matcher(nl < 0 ? raw : raw.substring(0, nl))
                .replaceFirst("")
                .trim();
    }

    private static boolean engineGenerated(SQLException ex, String raw) {
        ServerErrorMessage sem = serverError(ex);
        if (sem != null) {
            return sem.getConstraint() != null || sem.getTable() != null;
        }
        return ENGINE_MARKERS.matcher(raw).find();
    }

    private static ServerErrorMessage serverError(SQLException ex) {
        return ex instanceof PSQLException pg ? pg.getServerErrorMessage() : null;
    }

    /** Sustituye identificadores físicos por su término de negocio. */
    static String redact(String message) {
        String out = ROUTINE_PREFIX.matcher(message).replaceFirst("");
        out = SCHEMA_PREFIX.matcher(out).replaceAll("");
        out = replaceAll(KEY_COLUMN, out, m -> humanize(m.group(1)));
        out = replaceAll(TABLE_TOKEN, out, m -> TABLE_TERMS.get(m.group(1)));
        out = RESIDUAL_TABLE.matcher(out).replaceAll("registro");
        return out.replaceAll("\\s{2,}", " ").trim();
    }

    private static String replaceAll(Pattern pattern, String input,
                                     Function<Matcher, String> replacer) {
        Matcher m = pattern.matcher(input);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            m.appendReplacement(sb, Matcher.quoteReplacement(replacer.apply(m)));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    private static String humanize(String identifier) {
        return identifier.toLowerCase(Locale.ROOT).replace('_', ' ');
    }

    private static String truncate(String s) {
        return s.length() <= MAX_LENGTH ? s : s.substring(0, MAX_LENGTH) + "…";
    }

    /** Recorrido en anchura por {@code getNextException} y {@code getCause}. */
    private static Iterable<SQLException> chain(SQLException head) {
        List<SQLException> out = new ArrayList<>();
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        Deque<Throwable> pending = new ArrayDeque<>();
        enqueue(pending, head);
        while (!pending.isEmpty()) {
            Throwable t = pending.poll();
            if (!seen.add(t)) {
                continue;
            }
            if (t instanceof SQLException sql) {
                out.add(sql);
                enqueue(pending, sql.getNextException());
            }
            enqueue(pending, t.getCause());
        }
        return out;
    }

    private static void enqueue(Deque<Throwable> pending, Throwable t) {
        if (t != null) {
            pending.add(t);
        }
    }
}
