import { useMemo, useState } from "react";

/**
 * Multi-select dropdown with checkboxes. Used for the "checked
 * roles", "checked users", "checked microservices" binding UIs
 * that the backend exposes — they all return a list of items
 * with a `checked` flag, and the page toggles which items are
 * bound.
 *
 * We keep it uncontrolled (the parent passes the full list and
 * receives an `onChange` with the new checked set) so the source
 * of truth is always the backend's response.
 */
export interface MultiSelectOption<T extends { id: number }> {
  value: T;
  label: string;
  description?: string;
}

export interface MultiSelectProps<T extends { id: number }> {
  options: MultiSelectOption<T>[];
  selectedIds: Set<number>;
  onChange: (next: Set<number>) => void;
  placeholder?: string;
  emptyText?: string;
}

export function MultiSelect<T extends { id: number }>({
  options,
  selectedIds,
  onChange,
  placeholder = "Selecciona…",
  emptyText = "Sin opciones.",
}: MultiSelectProps<T>) {
  const [open, setOpen] = useState(false);

  const summary = useMemo(() => {
    if (selectedIds.size === 0) return placeholder;
    if (selectedIds.size === 1) {
      const id = selectedIds.values().next().value as number;
      const found = options.find((o) => o.value.id === id);
      return found?.label ?? `${selectedIds.size} seleccionado`;
    }
    return `${selectedIds.size} seleccionados`;
  }, [selectedIds, options, placeholder]);

  function toggle(id: number) {
    const next = new Set(selectedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    onChange(next);
  }

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        aria-haspopup="listbox"
        className="flex w-full items-center justify-between rounded border border-slate-300 bg-white px-3 py-2 text-left text-sm text-slate-700 hover:bg-slate-50"
      >
        <span className="truncate">{summary}</span>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 20 20"
          fill="currentColor"
          className="h-4 w-4 text-slate-400"
        >
          <path
            fillRule="evenodd"
            d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
            clipRule="evenodd"
          />
        </svg>
      </button>
      {open ? (
        <ul
          role="listbox"
          aria-multiselectable="true"
          className="absolute z-10 mt-1 max-h-60 w-full overflow-auto rounded border border-slate-200 bg-white py-1 shadow-lg"
        >
          {options.length === 0 ? (
            <li className="px-3 py-2 text-sm text-slate-500">{emptyText}</li>
          ) : (
            options.map((opt) => {
              const checked = selectedIds.has(opt.value.id);
              return (
                <li key={opt.value.id}>
                  <label
                    className={[
                      "flex cursor-pointer items-start gap-2 px-3 py-2 text-sm",
                      checked ? "bg-sky-50" : "hover:bg-slate-50",
                    ].join(" ")}
                  >
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={() => toggle(opt.value.id)}
                      className="mt-0.5 h-4 w-4 rounded border-slate-300 text-sky-600 focus:ring-sky-500"
                    />
                    <span className="flex-1">
                      <span className="block font-medium text-slate-800">
                        {opt.label}
                      </span>
                      {opt.description ? (
                        <span className="block text-xs text-slate-500">
                          {opt.description}
                        </span>
                      ) : null}
                    </span>
                  </label>
                </li>
              );
            })
          )}
        </ul>
      ) : null}
    </div>
  );
}
