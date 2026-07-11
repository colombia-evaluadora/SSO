import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import {
  useAdminQueries,
  useBindQueryRole,
  useCreateQuery,
  useDeleteQuery,
  useInvalidateQueryAdminAndCatalog,
  useQueryRolesChecked,
  useUnbindQueryRole,
  useUpdateQuery,
} from "@/hooks/useAdminQueries";
import { useExecuteQuery } from "@/hooks/useQueries";
import { useMicroservices } from "@/hooks/useMicroservices";
import type {
  QueryAdminResponse,
  QueryExecutionResponse,
  QueryParamValue,
} from "@/api/types";
import { extractQueryParams } from "@/lib/queryParams";
import { QueryFormDrawer } from "./QueryFormDrawer";
import type { QueryFormValues } from "@/schemas";

/**
 * The queries catalog: a single admin surface that both MANAGES
 * queries (create/edit/delete + role bindings) and EXECUTES them
 * (the "Ejecutar" action per row). Previously split across two
 * near-identical pages ({@code QueriesCatalogPage} at
 * {@code /admin/queries}, which only executed, and this admin
 * page, which only managed); they were merged because the admin
 * DTO ({@link QueryAdminResponse}) already carries everything the
 * executor needs (the SQL, uuid, and microserviceId). The old
 * {@code /admin/queries} path now redirects here.
 *
 * <p>Layout mirrors {@code EndpointsListPage}: list + create/edit
 * drawer + confirm-delete modal + a separate roles-binding modal,
 * plus the execute drawer opened by the row's "Ejecutar" button.
 *
 * <p>Two layout tricks worth flagging:
 * <ul>
 *   <li>The "Microservicio" column renders the
 *       microservice's {@code instanceName} or {@code serviceId}
 *       (not the numeric id) by cross-referencing
 *       {@link useMicroservices}. When the lookup returns
 *       nothing (id stale, row deleted), we fall back to
 *       {@code `#<id>`} so the table never blanks out.</li>
 *   <li>Roles column shows the bound count, not the names —
 *       long names would widen the column unpredictably; the
 *       "Roles" button opens the modal where the names
 *       surface.</li>
 * </ul>
 */
export function QueriesAdminPage() {
  const queries = useAdminQueries();
  const services = useMicroservices();
  const createQ = useCreateQuery();
  const updateQ = useUpdateQuery();
  const deleteQ = useDeleteQuery();
  const invalidateBoth = useInvalidateQueryAdminAndCatalog();
  const toast = useToast();

  const [editing, setEditing] = useState<QueryAdminResponse | null>(null);
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<QueryAdminResponse | null>(null);
  const [bindingRolesFor, setBindingRolesFor] =
    useState<QueryAdminResponse | null>(null);
  const [executing, setExecuting] = useState<QueryAdminResponse | null>(null);
  const [search, setSearch] = useState("");

  const filteredQueries = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return queries.data ?? [];
    return (queries.data ?? []).filter(
      (query) =>
        query.uuid.toLowerCase().includes(q) ||
        (query.type ?? "").toLowerCase().includes(q),
    );
  }, [queries.data, search]);

  async function handleSubmit(values: QueryFormValues & { id?: number }) {
    const body = {
      uuid: values.uuid,
      query: values.query,
      type: values.type || null,
      publicEnd: values.publicEnd,
      captcha: values.captcha,
      detail: values.detail || null,
      action: values.action || null,
      style: values.style || null,
      microserviceId: values.microserviceId ?? null,
    };
    if (values.id) {
      await updateQ.mutateAsync({ id: values.id, ...body });
      toast.show("Query actualizado", "success");
    } else {
      await createQ.mutateAsync(body);
      toast.show("Query creado", "success");
    }
    setEditing(null);
    setCreating(false);
  }

  async function confirmDelete() {
    if (!deleting) return;
    await deleteQ.mutateAsync(deleting.id);
    toast.show("Query eliminado", "success");
    setDeleting(null);
    invalidateBoth();
  }

  function closeRolesModal() {
    setBindingRolesFor(null);
    invalidateBoth();
  }

  const columns: Column<QueryAdminResponse>[] = [
    {
      key: "uuid",
      header: "UUID",
      render: (q) => (
        <span className="font-mono text-xs text-slate-900">{q.uuid}</span>
      ),
    },
    {
      key: "type",
      header: "Tipo",
      render: (q) => q.type ?? "—",
    },
    {
      key: "instance",
      header: "Instancia",
      render: (q) => {
        if (q.microserviceId == null) {
          return <span className="text-xs text-slate-400">Global</span>;
        }
        const m = services.data?.find((s) => s.id === q.microserviceId);
        return (
          <span className="text-xs">
            {m ? (
              <>
                <span className="font-mono">{m.instanceName ?? m.serviceId}</span>
                {m.dialect ? (
                  <span className="ml-1 text-slate-500">({m.dialect})</span>
                ) : null}
              </>
            ) : (
              <span className="text-slate-400">#{q.microserviceId}</span>
            )}
          </span>
        );
      },
    },
    {
      key: "publicEnd",
      header: "Público",
      render: (q) =>
        q.publicEnd ? (
          <span className="inline-flex rounded-full bg-emerald-50 px-2 py-0.5 text-[10px] font-medium text-emerald-700">
            Sí
          </span>
        ) : (
          <span className="text-xs text-slate-400">No</span>
        ),
    },
    {
      key: "roles",
      header: "Roles",
      align: "right",
      render: (q) => q.roleIds.length,
    },
    {
      key: "actions",
      header: "",
      align: "right",
      render: (q) => (
        <div className="flex justify-end gap-2">
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setExecuting(q)}
            data-testid={`execute-${q.id}`}
          >
            Ejecutar
          </Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setBindingRolesFor(q)}
            data-testid={`bind-roles-${q.id}`}
          >
            Roles
          </Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setEditing(q)}
            data-testid={`edit-${q.id}`}
          >
            Editar
          </Button>
          <Button
            size="sm"
            variant="danger"
            onClick={() => setDeleting(q)}
            data-testid={`delete-${q.id}`}
          >
            Eliminar
          </Button>
        </div>
      ),
    },
  ];

  return (
    <section>
      <header className="mb-4 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-slate-900">
            Queries Catalog
          </h1>
          <p className="mt-0.5 text-xs text-slate-500">
            Crea, vincula y ejecuta queries contra microservicios QUERY.
          </p>
        </div>
        <Button onClick={() => setCreating(true)} data-testid="new-query">
          + Nuevo query
        </Button>
      </header>

      <div className="mb-3">
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="Buscar por UUID o tipo…"
        />
      </div>

      <Table
        columns={columns}
        rows={filteredQueries}
        rowKey={(q) => q.id}
        loading={queries.isLoading}
        empty={
          queries.isError
            ? "No se pudo cargar el catálogo. ¿sso-admin está UP?"
            : search
              ? "Sin resultados."
              : "Aún no hay queries."
        }
      />

      <QueryFormDrawer
        open={creating || editing !== null}
        query={editing}
        onClose={() => {
          setCreating(false);
          setEditing(null);
        }}
        onSubmit={handleSubmit}
      />

      <Modal
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        title="Eliminar query"
        description={
          deleting ? `¿Seguro que quieres eliminar "${deleting.uuid}"?` : ""
        }
        footer={
          <>
            <Button variant="secondary" onClick={() => setDeleting(null)}>
              Cancelar
            </Button>
            <Button
              variant="danger"
              loading={deleteQ.isPending}
              onClick={() => void confirmDelete()}
            >
              Eliminar
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          Se eliminarán los bindings a roles asociados.
        </p>
      </Modal>

      {bindingRolesFor ? (
        <RolesBindingModal
          query={bindingRolesFor}
          onClose={closeRolesModal}
        />
      ) : null}

      <ExecuteDrawer query={executing} onClose={() => setExecuting(null)} />
    </section>
  );
}

/* ====================== roles binding modal ====================== */

interface RolesBindingModalProps {
  query: QueryAdminResponse;
  onClose: () => void;
}

/**
 * Two-button-per-row roles modal: each role gets a
 * "Vincular" / "Desvincular" button. We avoid a multi-select
 * checkbox list for two reasons:
 * <ol>
 *   <li>The roles that are unbound are a future-suggestion
 *       we don't want to encourage — the user should opt-IN
 *       a role, not opt-out from a wall of checkboxes.</li>
 *   <li>Each toggle is one HTTP round-trip; pairing them
 *       makes the consequence of each click explicit and
 *       trivially auditable in the role repository test
 *       suite.</li>
 * </ol>
 */
function RolesBindingModal({ query, onClose }: RolesBindingModalProps) {
  const roles = useQueryRolesChecked(query.id);
  const bind = useBindQueryRole();
  const unbind = useUnbindQueryRole();

  async function toggle(roleId: number, currentlyBound: boolean) {
    if (currentlyBound) {
      await unbind.mutateAsync({ id: query.id, roleId });
    } else {
      await bind.mutateAsync({ id: query.id, roleId });
    }
  }

  return (
    <Modal
      open
      onClose={onClose}
      title={`Roles para ${query.uuid}`}
      description={`Vincula o desvincula roles en este query. Los cambios son 1 round-trip por acción.`}
      footer={
        <Button variant="secondary" onClick={onClose}>
          Cerrar
        </Button>
      }
    >
      <ul className="divide-y divide-slate-200" data-testid="query-roles-list">
        {(roles.data ?? []).map((r) => (
          <li
            key={r.roleId}
            className="flex items-center justify-between py-2 text-sm"
          >
            <span className="font-medium text-slate-800">{r.name}</span>
            <Button
              size="sm"
              variant={r.checked ? "secondary" : "primary"}
              disabled={bind.isPending || unbind.isPending}
              loading={bind.isPending || unbind.isPending}
              onClick={() => void toggle(r.roleId, r.checked)}
              data-testid={`role-toggle-${r.roleId}`}
            >
              {r.checked ? "Desvincular" : "Vincular"}
            </Button>
          </li>
        ))}
        {roles.data && roles.data.length === 0 ? (
          <li className="py-2 text-sm text-slate-500">No hay roles creados.</li>
        ) : null}
      </ul>
    </Modal>
  );
}

/* ====================== execute drawer ====================== */

interface ExecuteDrawerProps {
  query: QueryAdminResponse | null;
  onClose: () => void;
}

/**
 * Runs a catalog query against its backing
 * {@code query-service-<instance>} container. Auto-generates one
 * {@code <Input>} per {@code :placeholder} token extracted from
 * the SQL, POSTs {uuid, params} via {@link useExecuteQuery}, and
 * renders the rows with the generic {@link ResultTable}. The
 * {@code Form} primitive is NOT used here because it auto-renders
 * Save semantics — wrong for "Execute".
 */
function ExecuteDrawer({ query, onClose }: ExecuteDrawerProps) {
  const services = useMicroservices();
  const execute = useExecuteQuery();
  const toast = useToast();

  const [paramValues, setParamValues] = useState<Record<string, QueryParamValue>>({});
  const [lastResult, setLastResult] = useState<QueryExecutionResponse | null>(null);

  // The instance bound to the query row. Falls back to the
  // canonical "query-service" when the query is global (no
  // MICROSERVICE_ID).
  const instanceName = useMemo(() => {
    if (!query || query.microserviceId == null) return null;
    return (
      services.data?.find((m) => m.id === query.microserviceId)?.instanceName ?? null
    );
  }, [query, services.data]);

  const paramNames = useMemo(
    () => (query ? extractQueryParams(query.query) : []),
    [query],
  );

  // Reset local state every time we switch query so a stale
  // result from a previous run doesn't leak into the new drawer.
  const queryKey = query?.id ?? null;
  useMemo(() => {
    setParamValues({});
    setLastResult(null);
    execute.reset();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryKey]);

  if (!query) return null;

  async function handleExecute() {
    if (!query) return;
    try {
      const result = await execute.mutateAsync({
        instanceName,
        body: {
          uuid: query.uuid,
          params: paramValues,
        },
      });
      setLastResult(result);
      if (result.length === 0) {
        toast.show("Consulta ejecutada — sin resultados", "success");
      } else {
        toast.show(`Consulta ejecutada — ${result.length} fila(s)`, "success");
      }
    } catch (err) {
      toast.show(`Error: ${(err as Error).message}`, "error");
    }
  }

  return (
    <Drawer
      open={!!query}
      onClose={onClose}
      title={`Ejecutar consulta ${query.uuid}`}
      description={
        instanceName
          ? `Instancia: query-service-${instanceName}`
          : "Instancia: query-service (canónica)"
      }
      width="lg"
    >
      <details className="mb-4 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs">
        <summary className="cursor-pointer font-medium text-slate-700">SQL</summary>
        <pre className="mt-2 overflow-x-auto whitespace-pre-wrap break-all text-[11px] text-slate-700">
          {query.query}
        </pre>
      </details>

      {paramNames.length === 0 ? (
        <p className="mb-4 text-sm text-slate-500">
          Esta consulta no requiere parámetros.
        </p>
      ) : (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void handleExecute();
          }}
          className="mb-4 grid gap-3"
        >
          {paramNames.map((name) => (
            <Input
              key={name}
              label={name}
              value={String(paramValues[name] ?? "")}
              onChange={(e) =>
                setParamValues((prev) => ({
                  ...prev,
                  [name]: e.target.value,
                }))
              }
              data-testid={`param-${name}`}
            />
          ))}
          <div className="flex justify-end gap-2">
            <Button
              variant="secondary"
              type="button"
              onClick={onClose}
              data-testid="cancel-execute"
            >
              Cerrar
            </Button>
            <Button
              type="submit"
              loading={execute.isPending}
              data-testid="run-execute"
            >
              Ejecutar
            </Button>
          </div>
        </form>
      )}

      {paramNames.length === 0 ? (
        <div className="mb-4 flex justify-end gap-2">
          <Button
            variant="secondary"
            type="button"
            onClick={onClose}
            data-testid="cancel-execute"
          >
            Cerrar
          </Button>
          <Button
            type="button"
            loading={execute.isPending}
            onClick={() => void handleExecute()}
            data-testid="run-execute"
          >
            Ejecutar
          </Button>
        </div>
      ) : null}

      {execute.isError ? (
        <div
          role="alert"
          className="mb-4 rounded border border-red-300 bg-red-50 px-3 py-2 text-xs text-red-700"
          data-testid="execute-error"
        >
          {(execute.error as Error).message}
        </div>
      ) : null}

      {lastResult && lastResult.length > 0 ? (
        <ResultTable rows={lastResult} />
      ) : lastResult ? (
        <p
          className="rounded border border-dashed border-slate-300 bg-white p-4 text-center text-sm text-slate-500"
          data-testid="execute-empty"
        >
          Sin resultados.
        </p>
      ) : null}
    </Drawer>
  );
}

/* ====================== result table ====================== */

interface ResultTableProps {
  rows: QueryExecutionResponse;
}

/**
 * Generic result table. The query-service response is
 * {@code List<Map<String, Object>>} where the map keys are the
 * JDBC column labels (insertion order preserved server-side and
 * on the wire). We read the keys from the first row to derive
 * the header.
 */
function ResultTable({ rows }: ResultTableProps) {
  const columns = useMemo<Column<Record<string, unknown>>[]>(() => {
    const first = rows[0];
    if (!first) return [];
    return Object.keys(first).map((key) => ({
      key,
      header: key,
      render: (row: Record<string, unknown>) => formatCell(row[key]),
    }));
  }, [rows]);

  return (
    <div className="mt-2">
      <p className="mb-2 text-xs text-slate-500">
        {rows.length} fila(s) devueltas
      </p>
      <Table
        columns={columns}
        rows={rows}
        rowKey={(row) => {
          const first = Object.values(row)[0];
          return first == null ? JSON.stringify(row) : String(first);
        }}
      />
    </div>
  );
}

function formatCell(value: unknown): string {
  if (value === null || value === undefined) return "—";
  if (typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }
  return String(value);
}
