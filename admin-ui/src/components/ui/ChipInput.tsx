import { useId, useState, type KeyboardEvent } from "react";

/**
 * Chip / tag input. Manages a list of strings the user can
 * extend by typing and either pressing <Enter> or typing a
 * {@code ,} (configurable). Empty-input trims guard against
 * adding blank chips. Removal is via the × on each chip.
 *
 * <p>Used by the {@code /admin/writes} form to edit the
 * {@code columns} + {@code keyColumns} arrays the backend
 * stores as a JSON-as-string (the helper that bridges the
 * two forms — {@code parseColumns} / {@code JSON.stringify} —
 * lives in {@code WriteFormDrawer}).
 *
 * <p>Design notes:
 * <ul>
 *   <li>The raw input is uncontrolled-looking but kept in
 *       {@code draft} state so the chip→commit cycle can
 *       reset it without losing focus.</li>
 *   <li>Keys: {@code Enter} commits, {@code ,} commits +
 *       consumes the comma (when {@code addOn !== "enter"}).
 *       The caret stays in the input after commit so the
 *       user can keep typing.</li>
 *   <li>Auto-commit on blur if the input is non-empty —
 *       avoiding the "I tabbed away and lost my chip"
 *       footgun.</li>
 *   <li>No built-in validation: the schema validates the
 *       resulting array length and patterns. This component
 *       stays headless on purpose so multiple form fields
 *       (column list, key-column list) can share it without
 *       cross-talk.</li>
 * </ul>
 */
export interface ChipInputProps {
  label: string;
  value: string[];
  onChange: (next: string[]) => void;
  required?: boolean;
  /** Inline error (red border + below message). Wins over `hint`. */
  error?: string | undefined;
  hint?: string | undefined;
  placeholder?: string;
  /** Root testid — siblings derive `{root}-input`, `{root}-chip-N`, etc. */
  dataTestId?: string;
  /** Commit trigger. Default {@code "both"}. */
  addOn?: "enter" | "comma" | "both";
}

export function ChipInput({
  label,
  value,
  onChange,
  required,
  error,
  hint,
  placeholder = "Añadir y pulsar Enter",
  dataTestId,
  addOn = "both",
}: ChipInputProps) {
  const [draft, setDraft] = useState("");
  const autoId = useId();
  const inputId = `${autoId}-input`;
  const describedBy: string[] = [];
  if (error) describedBy.push(`${autoId}-error`);
  if (hint && !error) describedBy.push(`${autoId}-hint`);

  function commit(raw: string) {
    const next = raw.trim();
    if (!next) return;
    onChange([...value, next]);
    setDraft("");
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Enter") {
      e.preventDefault();
      commit(draft);
      return;
    }
    if (
      addOn !== "enter" &&
      (e.key === "," || e.key === "Tab") &&
      draft.trim()
    ) {
      // Comma is consumed and treated as a commit. Tab also
      // commits (if non-empty) so the user doesn't lose the
      // chip when advancing to the next form field with the
      // keyboard.
      e.preventDefault();
      commit(draft);
    }
  }

  function removeAt(i: number) {
    onChange(value.filter((_, idx) => idx !== i));
  }

  return (
    <div data-testid={dataTestId}>
      <label
        htmlFor={inputId}
        className="mb-1 block text-sm font-medium text-slate-700"
      >
        {label}
        {required ? (
          <span aria-hidden="true" className="ml-0.5 text-red-600">
            *
          </span>
        ) : null}
      </label>
      <div
        className={[
          "flex flex-wrap items-center gap-1 rounded border bg-white p-1.5",
          "focus-within:ring-1",
          error
            ? "border-red-400 focus-within:border-red-500 focus-within:ring-red-500"
            : "border-slate-300 focus-within:border-sky-500 focus-within:ring-sky-500",
        ].join(" ")}
      >
        {value.map((chip, i) => (
          <span
            key={`${chip}-${i}`}
            className="inline-flex items-center gap-1 rounded bg-sky-50 px-2 py-0.5 text-xs text-sky-800"
            data-testid={dataTestId ? `${dataTestId}-chip-${i}` : undefined}
          >
            {chip}
            <button
              type="button"
              onClick={() => removeAt(i)}
              className="text-sky-600 hover:text-sky-900"
              aria-label={`Quitar ${chip}`}
              data-testid={dataTestId ? `${dataTestId}-remove-${i}` : undefined}
            >
              ×
            </button>
          </span>
        ))}
        <input
          id={inputId}
          type="text"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKeyDown}
          onBlur={() => {
            // Auto-commit any pending value when the field
            // loses focus so a quick "type + tab" doesn't
            // lose the chip.
            if (draft.trim()) commit(draft);
          }}
          placeholder={placeholder}
          aria-invalid={error ? true : undefined}
          aria-describedby={describedBy.join(" ") || undefined}
          className="min-w-[10rem] flex-1 border-none bg-transparent p-1 text-sm text-slate-900 outline-none"
          data-testid={dataTestId ? `${dataTestId}-input` : undefined}
        />
      </div>
      {hint && !error ? (
        <p id={`${autoId}-hint`} className="mt-1 text-xs text-slate-500">
          {hint}
        </p>
      ) : null}
      {error ? (
        <p
          id={`${autoId}-error`}
          role="alert"
          className="mt-1 text-xs text-red-600"
        >
          {error}
        </p>
      ) : null}
    </div>
  );
}
