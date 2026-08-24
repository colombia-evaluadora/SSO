/**
 * Tokenizer casero para el highlighting del textarea de SQL del
 * formulario de queries. Sin dependencias — el admin-ui no trae
 * ninguna librería de editor de código, y el alcance real es
 * angosto (colorear SQL estilo Postgres + los cuatro namespaces de
 * placeholder del catálogo), así que un tokenizer lineal a mano es
 * más barato que sumar CodeMirror/Prism sólo para esto.
 *
 * <p>No es un parser — no valida sintaxis ni balancea nada. Sólo
 * clasifica el texto en tramos para pintarlos con una clase CSS
 * distinta; una entrada rota simplemente se colorea "raro" en vez
 * de fallar.
 */

export type SqlTokenType =
  | "keyword"
  | "placeholder"
  | "string"
  | "identifier"
  | "comment"
  | "number"
  | "text";

export interface SqlToken {
  type: SqlTokenType;
  text: string;
}

/**
 * Set curado — dialecto Postgres, las palabras que de verdad
 * aparecen en el SQL/PLpgSQL de este catálogo (ver
 * {@code QueryAdminService.deriveExecutionMode} para los que
 * importan al backend: SELECT/WITH/CALL/INSERT/UPDATE). El resto
 * son de cortesía visual — no afectan validación, sólo highlighting.
 */
const KEYWORDS = new Set([
  "select", "from", "where", "join", "left", "right", "inner", "outer",
  "full", "cross", "on", "and", "or", "not", "in", "is", "null", "order",
  "by", "asc", "desc", "group", "having", "limit", "offset", "insert",
  "into", "values", "update", "set", "delete", "call", "with", "as",
  "cast", "distinct", "union", "all", "exists", "between", "like", "ilike",
  "case", "when", "then", "else", "end", "returning", "coalesce", "any",
  "array", "true", "false", "default", "primary", "key", "references",
  "constraint", "create", "alter", "drop", "table", "index", "view",
  "function", "procedure", "returns", "language", "plpgsql", "declare",
  "begin", "return", "raise", "exception", "loop", "for", "while", "if",
  "elsif", "materialized", "lateral", "over", "partition", "using",
  "conflict", "nothing", "do", "check", "unique", "foreign", "cascade",
  "restrict", "notice", "warning", "row_number", "count", "sum", "avg",
  "min", "max", "extract", "interval", "date", "timestamp", "text",
  "varchar", "bigint", "integer", "numeric", "boolean", "jsonb", "json",
]);

/** Mismos cuatro namespaces que {@code placeholderScanner.ts}. */
const PLACEHOLDER_RE = /^:(?:PARAM|BODY_RAW|BODY|QUERY|CONTEXT)(?:\.[A-Za-z][A-Za-z0-9_]*)+/i;

export function tokenizeSql(sql: string): SqlToken[] {
  const tokens: SqlToken[] = [];
  let i = 0;
  const n = sql.length;

  function push(type: SqlTokenType, text: string) {
    if (text === "") return;
    // Fusiona con el token anterior del mismo tipo — evita un
    // <span> por carácter para tramos de texto plano largos.
    const prev = tokens[tokens.length - 1];
    if (prev && prev.type === type && type === "text") {
      prev.text += text;
    } else {
      tokens.push({ type, text });
    }
  }

  while (i < n) {
    const rest = sql.slice(i);

    // Comentario de línea: -- hasta \n (sin consumir el \n, que se
    // procesa como texto plano en la siguiente vuelta).
    if (rest.startsWith("--")) {
      const nl = rest.indexOf("\n");
      const len = nl < 0 ? rest.length : nl;
      push("comment", rest.slice(0, len));
      i += len;
      continue;
    }

    // Comentario de bloque: /* ... */ (tolera que nunca cierre).
    if (rest.startsWith("/*")) {
      const close = rest.indexOf("*/");
      const len = close < 0 ? rest.length : close + 2;
      push("comment", rest.slice(0, len));
      i += len;
      continue;
    }

    // Placeholder del catálogo: :PARAM.X, :BODY.X.Y, etc. Se prueba
    // ANTES que el genérico ':' + identificador de PL/pgSQL (poco
    // frecuente en este catálogo, pero si aparece cae al texto
    // plano más abajo).
    const phMatch = PLACEHOLDER_RE.exec(rest);
    if (phMatch) {
      push("placeholder", phMatch[0]);
      i += phMatch[0].length;
      continue;
    }

    // String literal: '...' con comilla escapada como ''.
    if (rest[0] === "'") {
      let j = 1;
      while (j < rest.length) {
        if (rest[j] === "'") {
          if (rest[j + 1] === "'") { j += 2; continue; }
          j += 1;
          break;
        }
        j += 1;
      }
      push("string", rest.slice(0, j));
      i += j;
      continue;
    }

    // Identificador entre comillas dobles: "columna raro".
    if (rest[0] === '"') {
      let j = 1;
      while (j < rest.length && rest[j] !== '"') j += 1;
      j = Math.min(j + 1, rest.length);
      push("identifier", rest.slice(0, j));
      i += j;
      continue;
    }

    // Número: enteros y decimales (sin exponentes — no aparecen en
    // este catálogo, y complicarían el tokenizer sin beneficio real).
    const numMatch = /^\d+(\.\d+)?/.exec(rest);
    if (numMatch) {
      push("number", numMatch[0]);
      i += numMatch[0].length;
      continue;
    }

    // Palabra: keyword del set curado (case-insensitive) o
    // identificador/texto plano.
    const wordMatch = /^[A-Za-z_][A-Za-z0-9_]*/.exec(rest);
    if (wordMatch) {
      const word = wordMatch[0];
      const type: SqlTokenType = KEYWORDS.has(word.toLowerCase()) ? "keyword" : "text";
      push(type, word);
      i += word.length;
      continue;
    }

    // Cualquier otro carácter (espacio, puntuación, ':' suelto) —
    // texto plano, un carácter a la vez (se fusiona en push()).
    push("text", rest.charAt(0));
    i += 1;
  }

  return tokens;
}
