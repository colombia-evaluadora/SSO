import { useMemo } from "react";
import { useAdminQueries } from "@/hooks/useAdminQueries";
import {
  parseQueryDetail,
  resolveQueryTable,
} from "./dynamicForm";
import type { QueryAdminResponse } from "@/api/types";

/**
 * Dropdown que agrupa las queries por "tabla lógica". Para
 * mantenerlo sin metadata obligatoria, inferimos la tabla por
 * dos caminos (en orden):
 * <ol>
 *   <li>{@code detail.targetTable} — el admin lo declara en el
 *       JSON de detalle.</li>
 *   <li>Prefijo antes del primer {@code '.'} del uuid
 *       (convención "tabla.accion"): {@code users.list} →
 *       {@code users}.</li>
 * </ol>
 *
 * Si el uuid no tiene prefijo, cae en el grupo "Otras".
 *
 * <p>Por fila mostramos:
 * <ul>
 *   <li>uuid</li>
 *   <li>targetAction (si está declarado en metadata)</li>
 *   <li>flag "mut" si {@code writable === true} (cuando
 *       aterrice el backend con la columna)</li>
 * </ul>
 *
 * <p>El componente solo se ocupa del picker; el padre (la page)
 * mantiene el estado de selección y resuelve el resto.
 */

interface Props {
  value: QueryAdminResponse | null;
  onChange: (q: QueryAdminResponse | null) => void;
}

interface Group {
  table: string;
  rows: QueryAdminResponse[];
}

export function QueryActionPicker({ value, onChange }: Props) {
  const queries = useAdminQueries();

  const grouped: Group[] = useMemo(() => {
    const buckets = new Map<string, QueryAdminResponse[]>();
    (queries.data ?? []).forEach((q) => {
      const meta = parseQueryDetail(q.detail);
      const table = resolveQueryTable(q.uuid, meta);
      const list = buckets.get(table) ?? [];
      list.push(q);
      buckets.set(table, list);
    });
    return Array.from(buckets.entries())
      .map(([table, rows]): Group => ({
        table,
        rows: rows.sort((a, b) => a.uuid.localeCompare(b.uuid)),
      }))
      .sort((a, b) => a.table.localeCompare(b.table));
  }, [queries.data]);

  if (queries.isLoading) {
    return (
      <p className="text-sm text-slate-500" data-testid="picker-loading">
        Cargando catálogo…
      </p>
    );
  }
  if (queries.isError) {
    return (
      <p className="text-sm text-red-700" data-testid="picker-error">
        No se pudo cargar el catálogo. ¿sso-admin está UP?
      </p>
    );
  }
  if (grouped.length === 0) {
    return (
      <p className="text-sm text-slate-500" data-testid="picker-empty">
        No hay queries catalogadas todavía.
      </p>
    );
  }

  return (
    <select
      className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
      value={value?.id ?? ""}
      onChange={(e) => {
        const id = Number(e.target.value);
        if (Number.isNaN(id) || id === 0) {
          onChange(null);
          return;
        }
        onChange((queries.data ?? []).find((q) => q.id === id) ?? null);
      }}
      data-testid="action-picker"
      aria-label="Acción a ejecutar"
    >
      <option value="">— Elegí una acción —</option>
      {grouped.map((g) => (
        <optgroup key={g.table} label={g.table}>
          {g.rows.map((q) => {
            const meta = parseQueryDetail(q.detail);
            const isMut = (q as { writable?: boolean }).writable === true;
            const targetAction = meta.targetAction
              ? ` · ${meta.targetAction}`
              : "";
            const mutBadge = isMut ? " (mut)" : "";
            return (
              <option key={q.id} value={q.id}>
                {q.uuid}
                {targetAction}
                {mutBadge}
              </option>
            );
          })}
        </optgroup>
      ))}
    </select>
  );
}
