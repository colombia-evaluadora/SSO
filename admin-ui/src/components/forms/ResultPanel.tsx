import { ApiError } from "@/api/client";

/**
 * Muestra el resultado de ejecutar una query. Tiene tres ramas:
 * <ul>
 *   <li>Cargando — texto placeholder ("Ejecutando…").</li>
 *   <li>Error — banner rojo con el mensaje del {@link ApiError}
 *       (que ya viene sanitizado del backend, code + message +
 *       timestamp).</li>
 *   <li>Datos — si es un array:
 *     <ul>
 *       <li>Vacío → mensaje "Sin resultados".</li>
 *       <li>Con filas → tabla cuyas columnas se infieren de la
 *           primera fila. Los nombres vienen de
 *           {@code ResultSetMetaData.getColumnLabel(i)} del JDBC
 *           driver — los respeta el query-service.</li>
 *     </ul>
 *     Si NO es array, fallback a un JSON preformateado (caso
 *     "RETORNAR id" en un INSERT CTE → 1 fila, 1 columna, o un
 *     status textual).</li>
 * </ul>
 *
 * <p>El formateo de la tabla es deliberadamente minimal — los
 * valores se renderizan con {@code String(...)} y los null
 * como "—" para que filas con campos faltantes no rompan el
 * layout. Si en el futuro hace falta formato por columna (fechas,
 * números con separador de miles), esto es el único punto que
 * cambiar.
 */

interface Props {
  loading?: boolean;
  error?: ApiError | Error | null;
  data?: unknown;
  emptyHint?: string;
}

function renderCell(value: unknown): string {
  if (value == null) return "—";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

export function ResultPanel({
  loading,
  error,
  data,
  emptyHint = "Sin resultados.",
}: Props) {
  if (loading) {
    return (
      <p
        className="text-sm text-slate-500"
        role="status"
        data-testid="result-loading"
      >
        Ejecutando…
      </p>
    );
  }
  if (error) {
    return (
      <div
        role="alert"
        className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
        data-testid="result-error"
      >
        <div className="font-medium">✗ {error.message}</div>
        {error instanceof ApiError && error.code ? (
          <div className="mt-0.5 text-xs opacity-70">código: {error.code}</div>
        ) : null}
      </div>
    );
  }
  if (data == null) {
    return (
      <p className="text-xs text-slate-400" data-testid="result-empty-hint">
        El resultado se mostrará acá después de ejecutar.
      </p>
    );
  }

  if (Array.isArray(data)) {
    if (data.length === 0) {
      return (
        <p
          className="text-sm text-slate-500"
          data-testid="result-empty"
        >
          {emptyHint}
        </p>
      );
    }
    const first = data[0] as Record<string, unknown>;
    const cols =
      first && typeof first === "object" && !Array.isArray(first)
        ? Object.keys(first)
        : [];

    return (
      <div
        className="overflow-x-auto rounded border border-slate-200"
        data-testid="result-rows"
      >
        <table className="min-w-full divide-y divide-slate-200 text-xs">
          <thead className="bg-slate-50">
            <tr>
              {cols.map((c) => (
                <th
                  key={c}
                  className="px-2 py-1 text-left font-medium uppercase tracking-wide text-slate-600"
                >
                  {c}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {data.map((row, i) => {
              const rec =
                row && typeof row === "object" && !Array.isArray(row)
                  ? (row as Record<string, unknown>)
                  : {};
              return (
                <tr key={i} className="hover:bg-slate-50">
                  {cols.map((c) => (
                    <td
                      key={c}
                      className="px-2 py-1 font-mono text-slate-800"
                    >
                      {renderCell(rec[c])}
                    </td>
                  ))}
                </tr>
              );
            })}
          </tbody>
        </table>
        <p className="border-t border-slate-100 bg-slate-50 px-2 py-1 text-[11px] text-slate-500">
          {data.length} fila{data.length === 1 ? "" : "s"}
        </p>
      </div>
    );
  }

  // Single object / status response (e.g. INSERT ... RETURNING id)
  return (
    <pre
      className="overflow-x-auto rounded border border-slate-200 bg-slate-50 p-3 text-xs text-slate-800"
      data-testid="result-status"
    >
      {JSON.stringify(data, null, 2)}
    </pre>
  );
}
