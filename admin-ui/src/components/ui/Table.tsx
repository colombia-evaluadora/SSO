import type { ReactNode } from "react";

/**
 * Generic data table. Renders a header row from the {@link columns}
 * descriptor and a body row per item via the {@link renderRow}
 * callback. No built-in sort/pagination — we keep that logic in
 * the page (the data shape is page-specific; pushing it down to a
 * generic table means leaking query state into the primitive).
 *
 * Columns can have a `width` and `align`. The `accessor` is for
 * typed key access; the cell renderer is the full escape hatch
 * when you need a custom cell.
 */
export interface Column<T> {
  key: string;
  header: ReactNode;
  render: (row: T) => ReactNode;
  width?: string;
  align?: "left" | "right" | "center";
}

export interface TableProps<T> {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string | number;
  empty?: ReactNode;
  loading?: boolean;
}

export function Table<T>({
  columns,
  rows,
  rowKey,
  empty,
  loading,
}: TableProps<T>) {
  if (loading && rows.length === 0) {
    return (
      <div
        role="status"
        className="rounded border border-slate-200 bg-white p-8 text-center text-sm text-slate-500"
      >
        Cargando…
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="rounded border border-dashed border-slate-300 bg-white p-8 text-center text-sm text-slate-500">
        {empty ?? "Sin resultados."}
      </div>
    );
  }
  return (
    <div className="overflow-hidden rounded border border-slate-200 bg-white">
      <table className="w-full text-sm">
        <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
          <tr>
            {columns.map((c) => (
              <th
                key={c.key}
                scope="col"
                style={c.width ? { width: c.width } : undefined}
                className={[
                  "px-3 py-2 font-medium",
                  c.align === "right" && "text-right",
                  c.align === "center" && "text-center",
                ]
                  .filter(Boolean)
                  .join(" ")}
              >
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((row) => (
            <tr key={rowKey(row)} className="hover:bg-slate-50">
              {columns.map((c) => (
                <td
                  key={c.key}
                  className={[
                    "px-3 py-2 align-middle text-slate-700",
                    c.align === "right" && "text-right",
                    c.align === "center" && "text-center",
                  ]
                    .filter(Boolean)
                    .join(" ")}
                >
                  {c.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
