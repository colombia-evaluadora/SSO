import { useRef, type ChangeEvent, type UIEvent } from "react";
import { tokenizeSql, type SqlTokenType } from "@/lib/sqlHighlighter";

/**
 * Textarea de SQL con highlighting — sin librería de editor. La
 * técnica es la clásica "overlay": un {@code <textarea>} REAL,
 * transparente, encima de un {@code <pre>} que pinta el mismo texto
 * tokenizado con color por debajo. Los dos comparten fuente,
 * tamaño, padding y line-height EXACTOS (ver las clases
 * compartidas más abajo) para que el caret y la selección del
 * textarea caigan justo sobre el carácter que el `<pre>` pintó.
 *
 * <p>Por qué no un editor de código real (CodeMirror/Monaco): el
 * admin-ui no tiene ninguna dependencia de editor hoy, y el alcance
 * es angosto (colorear SQL + los cuatro namespaces de placeholder
 * del catálogo) — un overlay sobre un textarea nativo da
 * highlighting sin sumar ~150-250KB de bundle ni renunciar al
 * undo/spellcheck/autoresize nativos del navegador.
 *
 * <p>El scroll se sincroniza a mano ({@link handleScroll}): el
 * `<pre>` no es interactivo (`pointer-events-none`), así que el
 * usuario sólo interactúa con el `<textarea>` transparente de
 * encima; el `<pre>` sólo sigue su scrollTop/scrollLeft.
 */
const TOKEN_CLASS: Record<SqlTokenType, string> = {
  keyword: "text-sky-700 font-semibold",
  placeholder: "text-emerald-700 font-semibold",
  string: "text-amber-700",
  identifier: "text-fuchsia-700",
  comment: "text-slate-400 italic",
  number: "text-orange-700",
  text: "text-slate-900",
};

/** Clases compartidas EXACTAS entre el textarea y el pre — cualquier
 *  diferencia (padding, line-height, tamaño de fuente) desalinea el
 *  caret real respecto al texto pintado debajo. */
const SHARED_CLASSES =
  "absolute inset-0 m-0 h-full w-full whitespace-pre-wrap break-words " +
  "px-3 py-2 font-mono text-xs leading-5";

interface SqlEditorProps {
  value: string;
  onChange: (next: string) => void;
  rows?: number;
  placeholder?: string;
  invalid?: boolean;
  ariaLabel?: string;
}

export function SqlEditor({
  value,
  onChange,
  rows = 6,
  placeholder,
  invalid,
  ariaLabel,
}: SqlEditorProps) {
  const preRef = useRef<HTMLPreElement>(null);

  function handleChange(e: ChangeEvent<HTMLTextAreaElement>) {
    onChange(e.target.value);
  }

  function handleScroll(e: UIEvent<HTMLTextAreaElement>) {
    if (!preRef.current) return;
    preRef.current.scrollTop = e.currentTarget.scrollTop;
    preRef.current.scrollLeft = e.currentTarget.scrollLeft;
  }

  const tokens = tokenizeSql(value);

  return (
    <div
      className={[
        // resize-y + overflow-auto: el contenedor (no el textarea)
        // es lo que el usuario arrastra — el pre y el textarea de
        // adentro son `absolute inset-0`, así que siguen el alto
        // del contenedor automáticamente sin código de sync extra.
        // Antes `resize-none` vivía en el textarea y `overflow-hidden`
        // en este div, así que no había NADA que se pudiera agarrar
        // para ampliar el campo.
        "relative resize-y overflow-auto rounded border bg-white",
        invalid
          ? "border-red-400 focus-within:border-red-500 focus-within:ring-1 focus-within:ring-red-500"
          : "border-slate-300 focus-within:border-sky-500 focus-within:ring-1 focus-within:ring-sky-500",
      ].join(" ")}
      style={{ minHeight: `${rows * 1.25 + 1}rem` }}
    >
      {/* Capa de abajo: el texto coloreado. aria-hidden — el
          contenido accesible es el textarea de encima. */}
      <pre
        ref={preRef}
        aria-hidden="true"
        className={SHARED_CLASSES + " overflow-auto text-slate-900"}
      >
        {value.length === 0 ? (
          // Placeholder pintado a mano: el textarea real también
          // muestra su propio placeholder nativo, pero queda
          // ESCONDIDO detrás de este <pre> opaco cuando está vacío
          // — sin esto el campo se vería en blanco hasta el primer
          // carácter.
          <span className="text-slate-400">{placeholder}</span>
        ) : (
          tokens.map((t, idx) => (
            <span key={idx} className={TOKEN_CLASS[t.type]}>
              {t.text}
            </span>
          ))
        )}
        {/* Newline final para que el pre nunca quede un carácter
            más corto que el textarea (afecta el alto del scroll). */}
        {"\n"}
      </pre>
      <textarea
        value={value}
        onChange={handleChange}
        onScroll={handleScroll}
        spellCheck={false}
        aria-label={ariaLabel}
        aria-invalid={invalid ? true : undefined}
        className={
          SHARED_CLASSES +
          " resize-none overflow-auto bg-transparent text-transparent caret-slate-900 outline-none"
        }
      />
    </div>
  );
}
