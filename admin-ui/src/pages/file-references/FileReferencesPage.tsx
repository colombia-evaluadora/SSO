import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { useToast } from "@/components/ui/Toast";
import { useMicroservices } from "@/hooks/useMicroservices";
import { useMicroserviceTables } from "@/hooks/useMicroserviceTables";
import { useFileReference, useUpsertFileReference } from "@/hooks/useFileReferences";

/**
 * V-file-reference-admin — pantalla para inspeccionar y corregir a
 * mano una fila de {@code public.file_reference_location} (V143/
 * V147): el registro global que le dice a file-service en qué
 * {@code schema.tabla} vive cada {@code pk_tarchivo}.
 *
 * <p>Nace de un caso real: {@code pk_tarchivo=490026} quedó
 * huérfano de este registro (escrito por una instancia de
 * file-service previa a que existiera el INSERT correspondiente) y
 * el visor devolvía 404 aunque el archivo y su fila de negocio
 * existieran perfectamente. Repararlo exigió un INSERT manual
 * contra el servidor — esta pantalla es la versión HTTP de esa
 * misma operación, con selects de schema/tabla poblados desde el
 * catálogo REAL de un query-service (mismo endpoint {@code GET
 * /query-service-<instance>/tables} que ya usa el picker de Writes,
 * ver {@code WriteFormDrawer.TablePicker}) en vez de texto libre —
 * así el operador no puede escribir un schema/tabla que no exista.
 *
 * <p>No es una lista: es una búsqueda por {@code pk_tarchivo}. El
 * catálogo tiene cientos de miles de filas de archivo; no hay una
 * vista "todas las referencias" que tenga sentido operar a mano.
 */
export function FileReferencesPage() {
  const [pkInput, setPkInput] = useState("");
  const [searchedPk, setSearchedPk] = useState<number | null>(null);

  const reference = useFileReference(searchedPk);
  const toast = useToast();

  function handleSearch(e: React.FormEvent) {
    e.preventDefault();
    const n = Number(pkInput);
    if (!Number.isInteger(n) || n <= 0) {
      toast.show("pk_tarchivo debe ser un entero positivo", "error");
      return;
    }
    setSearchedPk(n);
  }

  return (
    <div className="max-w-2xl">
      <h1 className="mb-1 text-lg font-semibold text-slate-900">
        Referencias de archivo
      </h1>
      <p className="mb-4 text-sm text-slate-500">
        Busca un <code className="rounded bg-slate-100 px-1">pk_tarchivo</code>{" "}
        y revisa o corrige en qué schema.tabla lo resuelve file-service.
      </p>

      <form onSubmit={handleSearch} className="flex items-end gap-2">
        <Input
          label="pk_tarchivo"
          value={pkInput}
          onChange={(e) => setPkInput(e.target.value)}
          type="number"
          min={1}
          className="w-48"
          data-testid="file-reference-pk-input"
        />
        <Button type="submit" data-testid="file-reference-search">
          Buscar
        </Button>
      </form>

      {searchedPk != null ? (
        <div className="mt-6">
          {reference.isLoading ? (
            <p className="text-sm text-slate-500">Buscando…</p>
          ) : reference.isError ? (
            <p role="alert" className="text-sm text-red-600">
              No se pudo consultar la referencia.
            </p>
          ) : (
            <ReferencePanel pk={searchedPk} current={reference.data ?? null} />
          )}
        </div>
      ) : null}
    </div>
  );
}

function ReferencePanel({
  pk,
  current,
}: {
  pk: number;
  current: { schemaName: string; tableName: string; urls3: string | null; createdAt: string } | null;
}) {
  const toast = useToast();
  const upsert = useUpsertFileReference();
  const services = useMicroservices();
  const queryServices = useMemo(
    () => (services.data ?? []).filter((m) => m.kind === "QUERY"),
    [services.data],
  );

  const [serviceId, setServiceId] = useState<number | null>(null);
  const [schema, setSchema] = useState("");
  const [table, setTable] = useState("");

  const selectedMs = queryServices.find((m) => m.id === serviceId) ?? null;
  const tablesSource =
    selectedMs && selectedMs.instanceName
      ? { instanceName: selectedMs.instanceName, dialect: selectedMs.dialect ?? selectedMs.instanceName }
      : null;
  const tables = useMicroserviceTables(tablesSource);

  const schemas = useMemo(() => {
    const set = new Set<string>();
    for (const t of tables.data ?? []) {
      if (t.schema) set.add(t.schema);
    }
    return Array.from(set).sort();
  }, [tables.data]);

  const tablesInSchema = useMemo(
    () => (tables.data ?? []).filter((t) => t.schema === schema),
    [tables.data, schema],
  );

  async function handleSave() {
    if (!schema || !table) {
      toast.show("Elige schema y tabla antes de guardar", "error");
      return;
    }
    try {
      await upsert.mutateAsync({ pk, body: { schemaName: schema, tableName: table } });
      toast.show("Referencia guardada", "success");
    } catch (e) {
      toast.show(e instanceof Error ? e.message : "No se pudo guardar la referencia", "error");
    }
  }

  return (
    <div className="space-y-6">
      <div
        className="rounded border border-slate-200 bg-slate-50 p-4"
        data-testid="file-reference-current"
      >
        <h2 className="mb-2 text-sm font-medium text-slate-700">
          Estado actual
        </h2>
        {current ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
            <dt className="text-slate-500">Schema</dt>
            <dd className="font-mono text-slate-900">{current.schemaName}</dd>
            <dt className="text-slate-500">Tabla</dt>
            <dd className="font-mono text-slate-900">{current.tableName}</dd>
            <dt className="text-slate-500">urls3</dt>
            <dd className="break-all font-mono text-slate-900">
              {current.urls3 ?? <span className="text-slate-400">— (reserva sin cerrar)</span>}
            </dd>
            <dt className="text-slate-500">Registrado</dt>
            <dd className="text-slate-900">{new Date(current.createdAt).toLocaleString()}</dd>
          </dl>
        ) : (
          <p className="text-sm text-amber-700" data-testid="file-reference-not-found">
            No hay ninguna referencia registrada para pk_tarchivo={pk}. Puede ser
            un pk inexistente, o una fila huérfana (escrita por una versión
            anterior de file-service que aún no registraba aquí) — usa el
            formulario de abajo para crearla, si sabes en qué tabla vive
            realmente el archivo.
          </p>
        )}
      </div>

      <div className="rounded border border-slate-200 p-4">
        <h2 className="mb-3 text-sm font-medium text-slate-700">
          {current ? "Corregir referencia" : "Registrar referencia"}
        </h2>

        <div>
          <label
            htmlFor="file-reference-service"
            className="mb-1 block text-sm font-medium text-slate-700"
          >
            Query service
          </label>
          <select
            id="file-reference-service"
            value={serviceId == null ? "" : String(serviceId)}
            onChange={(e) => {
              setServiceId(e.target.value === "" ? null : Number(e.target.value));
              setSchema("");
              setTable("");
            }}
            className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
            data-testid="file-reference-service-select"
          >
            <option value="">— elegir —</option>
            {queryServices.map((m) => (
              <option key={m.id} value={String(m.id)}>
                #{m.id} · {m.instanceName ?? m.serviceId}
                {m.dialect ? ` (${m.dialect})` : ""}
              </option>
            ))}
          </select>
          {queryServices.length === 0 && !services.isLoading ? (
            <p className="mt-1 text-[11px] text-slate-500">
              No hay query-services aprovisionados aún.
            </p>
          ) : null}
        </div>

        {tablesSource ? (
          <div className="mt-3 grid grid-cols-2 gap-3">
            <div>
              <label
                htmlFor="file-reference-schema"
                className="mb-1 block text-sm font-medium text-slate-700"
              >
                Schema
              </label>
              <select
                id="file-reference-schema"
                value={schema}
                onChange={(e) => {
                  setSchema(e.target.value);
                  setTable("");
                }}
                className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                data-testid="file-reference-schema-select"
              >
                <option value="">— elegir —</option>
                {schemas.map((s) => (
                  <option key={s} value={s}>{s}</option>
                ))}
              </select>
              {tables.isFetching ? (
                <p className="mt-1 text-[10px] text-slate-500">cargando catálogo…</p>
              ) : null}
              {tables.isError ? (
                <p className="mt-1 text-xs text-red-600">
                  No se pudo cargar el catálogo de tablas.
                </p>
              ) : null}
            </div>
            <div>
              <label
                htmlFor="file-reference-table"
                className="mb-1 block text-sm font-medium text-slate-700"
              >
                Tabla
              </label>
              <select
                id="file-reference-table"
                value={table}
                onChange={(e) => setTable(e.target.value)}
                disabled={!schema}
                className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500 disabled:bg-slate-100"
                data-testid="file-reference-table-select"
              >
                <option value="">— elegir —</option>
                {tablesInSchema.map((t) => (
                  <option key={t.name} value={t.name}>{t.name}</option>
                ))}
              </select>
            </div>
          </div>
        ) : (
          <p className="mt-2 text-[11px] text-slate-500">
            Elige un query-service para cargar su catálogo real de schemas y tablas.
          </p>
        )}

        <div className="mt-4">
          <Button
            onClick={handleSave}
            loading={upsert.isPending}
            disabled={!schema || !table}
            data-testid="file-reference-save"
          >
            Guardar referencia
          </Button>
        </div>
        <p className="mt-2 text-[11px] text-slate-500">
          La tabla destino debe tener ya una fila con este pk_tarchivo —
          el backend la usa para leer <code>urls3</code> y mantener el
          registro sincronizado con el dato real; no se puede crear una
          referencia que apunte a la nada.
        </p>
      </div>
    </div>
  );
}
