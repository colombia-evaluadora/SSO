import { useMemo, useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { QueryActionPicker } from "./QueryActionPicker";
import { DynamicForm } from "@/components/forms/DynamicForm";
import { ResultPanel } from "@/components/forms/ResultPanel";
import { ApiError } from "@/api/client";
import { queriesApi } from "@/api/endpoints";
import { useMicroservices } from "@/hooks/useMicroservices";
import { useAdminQueries } from "@/hooks/useAdminQueries";
import {
  parseQueryDetail,
  type QueryMetadata,
} from "./dynamicForm";
import type { QueryAdminResponse, QueryExecutionResponse } from "@/api/types";

/**
 * Página "Dynamic CRUD" — la cara de consumidor del catálogo
 * para analistas que ejecutan queries pre-declaradas sin tocar
 * SQL.
 *
 * <p>Flujo:
 * <ol>
 *   <li>El picker lista las queries agrupadas por tabla (metadata
 *       {@code targetTable} o prefijo del uuid).</li>
 *   <li>Al elegir una, el {@link DynamicForm} auto-genera un
 *       input por cada {@code :placeholder} del SQL, respetando
 *       los {@code fieldTypes} / {@code validate} del JSON en
 *       {@code detail}.</li>
 *   <li>Submit → resuelve el {@code instanceName} del
 *       microservicio vinculado (o null si es global) y dispara
 *       {@code POST /query-service-<instance>/query}.</li>
 *   <li>El {@link ResultPanel} renderea filas (SELECT) o un
 *       JSON (caso {@code RETURNING} en un CTE).</li>
 * </ol>
 *
 * <p>Por qué v1 es read-only (sin writable):
 * <ul>
 *   <li>El backend no tiene la columna {@code writable} en la
 *       entidad {@code Query} todavía. La página se construye
 *       sobre las queries SELECT existentes (id=1..4) y deja
 *       listo el camino para mutaciones cuando aterrice el
 *       flag.</li>
 *   <li>El {@link QueryActionPicker} ya muestra la insignia
 *       "(mut)" si la query tiene {@code writable === true},
 *       para que cuando aterrice el soporte se vea
 *       automáticamente.</li>
 * </ul>
 */

export function QueriesDynamicPage() {
  const queries = useAdminQueries();
  const services = useMicroservices();
  const [selected, setSelected] = useState<QueryAdminResponse | null>(null);

  const meta: QueryMetadata = useMemo(
    () => (selected ? parseQueryDetail(selected.detail) : {}),
    [selected],
  );

  // Resolver instanceName del microservicio vinculado a la
  // query. Si la query es global (microserviceId == null),
  // queriesApi.execute usa la convención legacy
  // `query-service` (sigue siendo válido para el contenedor
  // por defecto).
  const instanceName = useMemo(() => {
    if (!selected || selected.microserviceId == null) return null;
    const m = services.data?.find((s) => s.id === selected.microserviceId);
    return m?.instanceName ?? null;
  }, [selected, services.data]);

  const exec = useMutation<QueryExecutionResponse, ApiError, Record<string, string>>({
    mutationFn: async (values) => {
      if (!selected) throw new ApiError(0, "NO_QUERY", "Sin query seleccionada");
      // Convertimos los numbers (campo declarado como
      // fieldTypes.XX === "number") a Number. El resto los
      // deja como string — MapSqlParameterSource acepta ambos.
      const params: Record<string, string | number> = {};
      for (const [k, v] of Object.entries(values)) {
        const t = meta.fieldTypes?.[k];
        if (t === "number" && v !== "" && !Number.isNaN(Number(v))) {
          params[k] = Number(v);
        } else if (t === "boolean") {
          params[k] = v;
        } else {
          params[k] = v;
        }
      }
      return queriesApi.execute(instanceName, {
        uuid: selected.uuid,
        params,
      });
    },
  });

  if (!queries.data) {
    return (
      <section>
        <p className="text-sm text-slate-500">Cargando catálogo…</p>
      </section>
    );
  }

  return (
    <section className="flex flex-col gap-4">
      <header>
        <h1 className="text-xl font-semibold text-slate-900">Dynamic CRUD</h1>
        <p className="mt-0.5 text-xs text-slate-500">
          Ejecuta queries catalogadas. La metadata en <code>detail</code>{" "}
          declara tipos de input, validación y workflow (cuando aplique).
        </p>
      </header>

      <div>
        <label
          htmlFor="action-picker"
          className="mb-1 block text-sm font-medium text-slate-700"
        >
          Acción
        </label>
        <QueryActionPicker
          value={selected}
          onChange={(q) => {
            setSelected(q);
            exec.reset();
          }}
        />
      </div>

      {selected ? (
        <div
          className="rounded border border-slate-200 bg-white p-4"
          data-testid="selected-query-panel"
        >
          <div className="mb-3 flex items-baseline justify-between">
            <div>
              <h2 className="font-mono text-sm text-slate-900">
                {selected.uuid}
                {meta.targetAction ? ` · ${meta.targetAction}` : ""}
              </h2>
              {meta.targetTable ? (
                <p className="mt-0.5 text-xs text-slate-500">
                  Tabla destino: <code className="font-mono">{meta.targetTable}</code>
                </p>
              ) : null}
              <p className="mt-0.5 text-[11px] text-slate-400">
                {selected.microserviceId == null
                  ? "Sin binding (global)"
                  : `Microservicio: #${selected.microserviceId}${
                      instanceName ? ` (${instanceName})` : ""
                    }`}
              </p>
            </div>
          </div>

          <DynamicForm
            sql={selected.query}
            detail={selected.detail}
            submitting={exec.isPending}
            onSubmit={async (v) => {
              exec.mutate(v);
            }}
            submitLabel="Ejecutar"
          />
        </div>
      ) : null}

      <ResultPanel
        loading={exec.isPending}
        error={exec.error ?? null}
        data={exec.data ?? null}
        emptyHint="La query devolvió 0 filas."
      />
    </section>
  );
}
