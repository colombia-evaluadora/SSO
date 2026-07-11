interface SearchInputProps {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
}

/**
 * Controlled search box with a clear ("×") button, shown only
 * when there's text to clear. Same visual/interaction pattern as
 * the search box inside {@code BindingTab} (case-insensitive
 * substring filter is the caller's responsibility — this
 * component is purely the input) — extracted here so every
 * `*ListPage` can filter its own dataset without duplicating the
 * markup.
 *
 * <p>{@code aria-label} is a fixed, generic string — deliberately
 * NOT mirroring {@code placeholder} — because several pages'
 * placeholders reference the same words as real form-field labels
 * (e.g. "Buscar por UUID…" vs. the Write form's "UUID" input),
 * which made {@code getByLabelText(/UUID/i)} in existing tests
 * match two elements. {@code data-testid="search-input"} is the
 * stable hook for tests instead.
 */
export function SearchInput({ value, onChange, placeholder }: SearchInputProps) {
  return (
    <div className="relative max-w-sm">
      <input
        type="search"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        aria-label="Buscar en la lista"
        data-testid="search-input"
        className={[
          "w-full rounded border border-slate-300 bg-white px-3 py-1.5 pr-8 text-sm",
          "text-slate-900 outline-none placeholder:text-slate-400",
          "focus:border-sky-500 focus:ring-1 focus:ring-sky-500",
        ].join(" ")}
      />
      {value.length > 0 ? (
        <button
          type="button"
          onClick={() => onChange("")}
          aria-label="Limpiar búsqueda"
          className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-0.5 text-slate-400 hover:text-slate-600"
        >
          ×
        </button>
      ) : null}
    </div>
  );
}
