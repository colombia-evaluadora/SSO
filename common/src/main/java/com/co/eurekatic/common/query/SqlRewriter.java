package com.co.eurekatic.common.query;

import java.util.Map;
import java.util.Set;

/**
 * V49-bis — reescribe un SQL del catálogo insertando
 * {@code cast(:PLACEHOLDER as TIPO)} para cada placeholder que tenga un tipo
 * declarado en {@code paramTypes}. Es el pegamento entre la metadata del
 * catálogo ({@code QUERY.PARAM_TYPES}) y el runtime de bind (donde ahora el
 * binder pasa los valores como texto puro y deja que PG haga el cast).
 *
 * <p><b>Por qué reescribir el SQL y no usar {@code setObject(k, v, sqlType)}</b>:
 * el camino JDBC obliga al driver a saber el tipo PG. Eso funciona para
 * escalares built-in pero falla con tipos del catálogo:
 * <ul>
 *   <li>DOMAIN types ({@code academico_test.bool_sn}, etc.) — el driver JDBC
 *       no los conoce y bindea como VARCHAR, PG devuelve "type does not exist"
 *       porque {@code search_path} no incluye {@code academico_test}.</li>
 *   <li>Funciones PG con firma específica — si la firma dice {@code (integer, bigint)}
 *       y el bind JDBC manda {@code character varying}, PG devuelve
 *       "function xxx(character varying, bigint) does not exist" aunque el
 *       autor haya declarado el tipo correcto en metadata.</li>
 * </ul>
 * El cast inline en SQL elimina esa dependencia: el binder pasa texto, PG
 * aplica el cast en su contexto (donde {@code search_path} sí resuelve).
 *
 * <p><b>Limitaciones del rewriter</b>: usa regex sobre el SQL para evitar el
 * problema clásico de parsear SQL genérico. Eso es suficiente para los
 * patrones que produce este codebase. Casos conocidos:
 * <ul>
 *   <li>String literal con comilla simple: NO se reescribe (el placeholder
 *       dentro de '...' es texto literal, no un bind).</li>
 *   <li>String literal con comilla doble (identificador entrecomillado):
 *       NO se reescribe.</li>
 *   <li>Escape de comilla simple: {@code 'it''s'} — dos comillas seguidas
 *       son un escape, no cierre.</li>
 *   <li>Comentarios single-line ({@code -- ...}) y multi-line
 *       ({@code /* ... *}{@code /}): NO se reescriben (cosmético pero
 *       predecible para tests que comparan strings).</li>
 *   <li>PL/pgSQL con bloques {@code $$...$$} — los placeholders dentro se
 *       reescriben porque el lexer no soporta dollar-quoting. Si el autor
 *       mete un placeholder en uno, el cast se inserta igual — PG falla
 *       con un mensaje claro. Fuera de alcance en V49-bis.</li>
 *   <li>Strings con escapes complejos ({@code E'\x08'}) — no contemplado.</li>
 * </ul>
 */
public final class SqlRewriter {

    private SqlRewriter() {}

    /**
     * Inserta {@code cast(:PLACEHOLDER as TIPO)} en el SQL para cada placeholder
     * declarado en {@code paramTypes}. Si un placeholder aparece en el SQL
     * pero NO está declarado, se queda como {@code :PLACEHOLDER} — la guardia
     * runtime del {@code QueryService} ya rechaza esos casos antes de llegar
     * aquí.
     *
     * <p>Si {@code paramTypes} es null o vacío, devuelve el SQL sin tocar
     * (legacy behavior).
     *
     * @param sql        el SQL del catálogo, tal cual lo carga
     *                   {@code QueryDefinition.query()}.
     * @param paramTypes mapa {@code placeholder → tipo} del catálogo. Keys en
     *                   MAYÚSCULAS ({@code "PARAM.ID"}, {@code "BODY.X.Y"}).
     * @return SQL reescrito con los casts insertados.
     */
    public static String rewrite(String sql, Map<String, String> paramTypes) {
        if (sql == null || sql.isEmpty()) return sql;
        if (paramTypes == null || paramTypes.isEmpty()) return sql;

        // Trabajamos sobre el SQL original (case-sensitive) porque el SQL puede
        // tener mezcla de mayúsculas/minúsculas que el autor eligió. El scanner
        // de placeholders trabaja sobre mayúsculas, pero el reemplazo se hace
        // sobre el texto original.
        //
        // Estrategia: tokenizar el SQL respetando literales y comentarios,
        // luego para cada token que sea un placeholder declarado, sustituir
        // por `cast(:PH as TIPO)`. El resto se deja tal cual.
        //
        // Implementación: regex que captura placeholders + contexto adyacente
        // para detectar si está dentro de un literal. Más simple que un
        // tokenizer completo y suficiente para los patrones del codebase.
        StringBuilder out = new StringBuilder(sql.length() + 64);
        int cursor = 0;
        int n = sql.length();

        // Regex de placeholder — case-insensitive sobre el SQL original
        // (V60). La convención es escribir los nombres en MAYÚSCULAS
        // (tanto en el SQL como en el catálogo), pero un autor que
        // escribe ":param.id" en lugar de ":PARAM.ID" no debería
        // hacer que el rewriter falle en silencio: el cast PG
        // quedaría sin insertar y el bind terminaría con un
        // "function xxx(character varying, bigint) does not
        // exist" críptico. La key con la que se busca en
        // {@code paramTypes} siempre va en MAYÚSCULAS (es lo que el
        // resto del codebase guarda y emite).
        java.util.regex.Pattern placeholder = java.util.regex.Pattern.compile(
                ":(PARAM|BODY|BODY_RAW|QUERY|CONTEXT)(\\.[A-Za-z][A-Za-z0-9_]*)+",
                java.util.regex.Pattern.CASE_INSENSITIVE);

        java.util.regex.Matcher m = placeholder.matcher(sql);
        // Estado del lexer — se mantiene entre matches para no desincronizarse
        // cuando se llama desde una posición intermedia del SQL. Si entre dos
        // matches el primero abrió un string y lo cerró, el siguiente empieza
        // con estado base de nuevo.
        LexerState state = LexerState.BASE;
        while (m.find()) {
            int start = m.start();
            int end = m.end();

            // Avanza el lexer desde `cursor` hasta `start` y devuelve el estado
            // resultante. Si el estado final es BASE, el placeholder está
            // fuera de literales/comentarios y se puede reescribir.
            state = advance(sql, cursor, start, state);
            if (!state.isBase()) {
                // Dentro de un literal o comentario — no tocar.
                out.append(sql, cursor, end);
                cursor = end;
                continue;
            }

            // Apendiza el texto entre cursor y el placeholder.
            out.append(sql, cursor, start);

            String ph = m.group();      // incluye el ':'
            String key = ph.substring(1).toUpperCase(java.util.Locale.ROOT);
            // Búsqueda case-insensitive: las keys en paramTypes vienen en
            // MAYÚSCULAS por convención, pero si el autor las metió en
            // minúsculas no fallamos el bind.
            String declaredType = paramTypes.get(key);
            if (declaredType == null) {
                for (Map.Entry<String, String> e : paramTypes.entrySet()) {
                    if (e.getKey().equalsIgnoreCase(key)) {
                        declaredType = e.getValue();
                        break;
                    }
                }
            }
            if (declaredType != null) {
                String pgCastName = ParamTypes.PG_CAST_NAME.get(declaredType);
                if (pgCastName != null) {
                    out.append("cast(").append(ph).append(" as ").append(pgCastName).append(")");
                } else {
                    // Tipo declarado pero no en PG_CAST_NAME — la validación
                    // al guardar ya lo habría rechazado, pero defensivamente
                    // dejamos el placeholder sin tocar.
                    out.append(ph);
                }
            } else {
                // Placeholder no declarado — la guardia runtime ya rechazó
                // el caso, pero si llegamos aquí, lo dejamos tal cual.
                out.append(ph);
            }
            cursor = end;
        }
        out.append(sql, cursor, n);
        return out.toString();
    }

    /**
     * Estado del lexer de SQL simplificado: lo que estamos procesando AHORA.
     * BASE = fuera de literales y comentarios. SINGLE = dentro de '...'.
     * DOUBLE = dentro de "...". LINE_COMMENT = dentro de -- .... BLOCK_COMMENT
     * = dentro de /* ... *{@code /}.
     */
    private enum LexerState {
        BASE, SINGLE, DOUBLE, LINE_COMMENT, BLOCK_COMMENT;

        boolean isBase() { return this == BASE; }
    }

    /**
     * Avanza el lexer desde {@code from} hasta {@code pos}, partiendo de
     * {@code initialState}, y devuelve el estado en {@code pos}.
     *
     * <p>Esto es la versión incremental del antiguo {@code isInsideLiteral}:
     * en lugar de resetear el estado a BASE cada llamada, lo recibimos y lo
     * devolvemos, lo que evita la desincronización cuando entre dos matches
     * hay un literal que se abre y se cierra.
     */
    private static LexerState advance(String sql, int from, int pos, LexerState initial) {
        LexerState s = initial;
        int i = from;
        while (i < pos) {
            char c = sql.charAt(i);
            char next = (i + 1 < pos) ? sql.charAt(i + 1) : '\0';
            switch (s) {
                case LINE_COMMENT:
                    if (c == '\n') s = LexerState.BASE;
                    i++;
                    break;
                case BLOCK_COMMENT:
                    if (c == '*' && next == '/') {
                        s = LexerState.BASE;
                        i += 2;
                    } else {
                        i++;
                    }
                    break;
                case SINGLE:
                    if (c == '\'') {
                        if (next == '\'') { // escape ''
                            i += 2;
                        } else {
                            s = LexerState.BASE;
                            i++;
                        }
                    } else {
                        i++;
                    }
                    break;
                case DOUBLE:
                    if (c == '"') {
                        s = LexerState.BASE;
                        i++;
                    } else {
                        i++;
                    }
                    break;
                case BASE:
                default:
                    if (c == '-' && next == '-') {
                        s = LexerState.LINE_COMMENT;
                        i += 2;
                    } else if (c == '/' && next == '*') {
                        s = LexerState.BLOCK_COMMENT;
                        i += 2;
                    } else if (c == '\'') {
                        s = LexerState.SINGLE;
                        i++;
                    } else if (c == '"') {
                        s = LexerState.DOUBLE;
                        i++;
                    } else {
                        i++;
                    }
                    break;
            }
        }
        return s;
    }

    /**
     * ¿El carácter en {@code pos} está dentro de un string literal o
     * comentario? Heurística basada en contar delimitadores abiertos
     * entre {@code from} y {@code pos}. Soporta:
     * <ul>
     *   <li>String literal con comilla simple: {@code '...'}</li>
     *   <li>String literal con comilla doble (identificador entrecomillado): {@code "..."}</li>
     *   <li>String literal con escape: {@code 'it''s'} (dos comillas = escape)</li>
     *   <li>Comentarios single-line: {@code -- ...}</li>
     *   <li>Comentarios multi-line: {@code /* ... *}{@code /}</li>
     * </ul>
     * No soporta dollar-quoting ({@code $$...$$}). Si alguien lo usa y mete
     * un placeholder adentro, el cast se inserta igual — el binder pasa
     * texto y PG parsea el cast como parte del string, lo cual falla con
     * un mensaje claro de PG.
     */
    private static boolean isInsideLiteral(String sql, int from, int pos) {
        // Mantenido por compatibilidad con tests que lo invocan directamente;
        // delega al nuevo {@link #advance} partiendo de BASE.
        return advance(sql, from, pos, LexerState.BASE) != LexerState.BASE;
    }

    /**
     * Devuelve los placeholders únicos que el rewriter va a sustituir
     * dado un SQL y un map de tipos. Útil para tests y para la guardia
     * runtime del QueryService.
     */
    public static Set<String> placeholdersToRewrite(String sql,
                                                    Map<String, String> paramTypes) {
        if (sql == null || sql.isEmpty() || paramTypes == null || paramTypes.isEmpty()) {
            return Set.of();
        }
        java.util.Set<String> out = new java.util.LinkedHashSet<>();
        for (String ph : PlaceholderScanner.scan(sql)) {
            if (paramTypes.containsKey(ph)) out.add(ph);
        }
        return out;
    }
}