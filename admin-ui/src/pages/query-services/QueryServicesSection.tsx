import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import {
  useCreateMicroservice,
  useDeleteMicroservice,
  useMicroservices,
  useUpdateMicroservice,
} from "@/hooks/useMicroservices";
import { useQueryServiceStatus, useRestartQueryService } from "@/hooks/useQueryServices";
import type { MicroserviceResponse } from "@/api/types";
import type { MicroserviceFormValues } from "@/schemas";
import { LogsModal } from "./LogsModal";
import { QueryServiceFormDrawer } from "./QueryServiceFormDrawer";

/**
 * The section that fully owns `kind=QUERY` microservices:
 * CRUD (create/edit/delete, which drives the provisioner sidecar)
 * AND ops (per-container status / logs / restart). It renders at
 * the bottom of the Microservicios page ({@code /admin/microservices},
 * see {@code MicroservicesListPage}) — the REST table sits above,
 * this QUERY table below — so there's no longer a separate
 * /admin/query-services route.
 *
 * <p>The list comes from {@link useMicroservices} filtered to
 * QUERY (not the separate query-services key) so the CRUD
 * mutations' cache invalidation refreshes this table too. Status
 * polls per row via {@link useQueryServiceStatus} (5s while
 * non-UP, idle once running/absent).
 */
export function QueryServicesSection() {
  const microservices = useMicroservices();
  const createMs = useCreateMicroservice();
  const updateMs = useUpdateMicroservice();
  const deleteMs = useDeleteMicroservice();
  const restart = useRestartQueryService();
  const toast = useToast();

  const [editing, setEditing] = useState<MicroserviceResponse | null>(null);
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<MicroserviceResponse | null>(null);
  const [logsFor, setLogsFor] = useState<MicroserviceResponse | null>(null);
  const [search, setSearch] = useState("");

  const rows = useMemo(
    () => (microservices.data ?? []).filter((m) => m.kind === "QUERY"),
    [microservices.data],
  );

  async function handleSubmit(values: MicroserviceFormValues & { id?: number }) {
    try {
      if (values.id) {
        await updateMs.mutateAsync(values as Parameters<typeof updateMs.mutateAsync>[0]);
        toast.show("Query service actualizado", "success");
      } else {
        await createMs.mutateAsync(values as Parameters<typeof createMs.mutateAsync>[0]);
        toast.show("Query service creado; aprovisionando…", "success");
      }
      setEditing(null);
      setCreating(false);
    } catch (err) {
      // The Form<T> wrapper already toasts the error; keep the
      // drawer open so the user can fix it.
      console.error("query service save failed", err);
    }
  }

  async function confirmDelete() {
    if (!deleting) return;
    await deleteMs.mutateAsync(deleting.id);
    toast.show("Query service eliminado", "success");
    setDeleting(null);
  }

  async function handleRestart(m: MicroserviceResponse) {
    try {
      await restart.mutateAsync(m.id);
      toast.show(`Reinicio solicitado — ${m.instanceName ?? m.serviceId}`, "success");
    } catch (err) {
      toast.show(
        `No se pudo reiniciar ${m.instanceName ?? m.serviceId}: ${(err as Error).message}`,
        "error",
      );
    }
  }

  const columns = useMemo<Column<MicroserviceResponse>[]>(
    () => [
      {
        key: "status",
        header: "Estado",
        width: "140px",
        render: (m) => <StatusCell microserviceId={m.id} />,
      },
      {
        key: "instance",
        header: "Instancia",
        render: (m) => (
          <div className="flex flex-col">
            <span className="font-mono text-xs text-slate-900">
              {m.instanceName ?? m.serviceId}
            </span>
            <span className="text-xs text-slate-500">{m.serviceId}</span>
          </div>
        ),
      },
      {
        key: "dialect",
        header: "Dialecto",
        render: (m) => m.dialect ?? "—",
      },
      {
        key: "jdbc",
        header: "JDBC URL",
        render: (m) =>
          m.jdbcUrl ? (
            <code className="block max-w-md truncate text-xs text-slate-700" title={m.jdbcUrl}>
              {m.jdbcUrl}
            </code>
          ) : (
            "—"
          ),
      },
      {
        key: "actions",
        header: "",
        align: "right",
        render: (m) => (
          <div className="flex justify-end gap-2">
            <Button
              size="sm"
              variant="secondary"
              onClick={() => setLogsFor(m)}
              data-testid={`view-logs-${m.id}`}
            >
              Ver logs
            </Button>
            <Button
              size="sm"
              variant="secondary"
              loading={restart.isPending && restart.variables === m.id}
              onClick={() => handleRestart(m)}
            >
              Reiniciar
            </Button>
            <Button
              size="sm"
              variant="secondary"
              onClick={() => setEditing(m)}
              data-testid={`edit-${m.id}`}
            >
              Editar
            </Button>
            <Button
              size="sm"
              variant="danger"
              onClick={() => setDeleting(m)}
              data-testid={`delete-${m.id}`}
            >
              Eliminar
            </Button>
          </div>
        ),
      },
    ],
    // restart.variables intentionally omitted — the per-row loading
    // check reads it fresh on each render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  const filteredRows = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(
      (m) =>
        (m.instanceName ?? m.serviceId).toLowerCase().includes(q) ||
        (m.dialect ?? "").toLowerCase().includes(q),
    );
  }, [rows, search]);

  return (
    <section className="border-t border-slate-200 pt-8">
      <header className="mb-4 flex items-center justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">Query Services</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            Instancias de <code>query-service</code> aprovisionadas por el sidecar ({rows.length}{" "}
            {rows.length === 1 ? "fila" : "filas"})
          </p>
        </div>
        <div className="flex items-center gap-4">
          <Legend />
          <Button onClick={() => setCreating(true)} data-testid="new-query-service">
            + Nuevo query service
          </Button>
        </div>
      </header>

      <div className="mb-3">
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="Buscar por instancia o dialecto…"
        />
      </div>

      <Table
        columns={columns}
        rows={filteredRows}
        rowKey={(m) => m.id}
        loading={microservices.isLoading}
        empty={
          microservices.isError
            ? "No se pudo cargar la lista. ¿sso-admin está UP?"
            : search
              ? "Sin resultados."
              : "Aún no hay query services. Crea uno con el botón de arriba."
        }
      />

      <QueryServiceFormDrawer
        open={creating || editing !== null}
        microservice={editing}
        onClose={() => {
          setCreating(false);
          setEditing(null);
        }}
        onSubmit={handleSubmit}
      />

      <Modal
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        title="Eliminar query service"
        description={`¿Seguro que quieres eliminar "${deleting?.serviceId}"? Esta acción no se puede deshacer.`}
        footer={
          <>
            <Button variant="secondary" onClick={() => setDeleting(null)}>
              Cancelar
            </Button>
            <Button
              variant="danger"
              loading={deleteMs.isPending}
              onClick={() => void confirmDelete()}
            >
              Eliminar
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          Esto también des-aprovisiona el contenedor asociado vía el sidecar.
        </p>
      </Modal>

      <LogsModal microservice={logsFor} onClose={() => setLogsFor(null)} />
    </section>
  );
}

function StatusCell({ microserviceId }: { microserviceId: number }) {
  const status = useQueryServiceStatus(microserviceId);
  const state = status.data?.state ?? null;
  const rawState = status.data?.rawState ?? null;
  const startedAt = status.data?.startedAt ?? null;

  if (status.isLoading && !status.data) {
    return <span className="text-xs text-slate-400">…</span>;
  }

  return (
    <div className="flex flex-col gap-0.5" data-testid={`status-cell-${microserviceId}`}>
      <StatusBadge state={state} />
      <span className="text-[10px] text-slate-400" title={rawState ?? undefined}>
        {startedAt ? formatStartedAt(startedAt) : ""}
      </span>
    </div>
  );
}

function Legend() {
  return (
    <div className="flex flex-wrap items-center gap-2 text-[10px] text-slate-500">
      <span>Leyenda:</span>
      <StatusBadge state="running" />
      <StatusBadge state="provisioning" />
      <StatusBadge state="exited" />
      <StatusBadge state="absent" />
    </div>
  );
}

function formatStartedAt(iso: string): string {
  // Container inspect returns RFC 3339 (e.g. "2026-06-24T15:04:05.123456789Z").
  // We render YYYY-MM-DD HH:MM:SS in the operator's locale — short
  // enough to fit in the cell, exact enough to compare across rows.
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(
    d.getHours(),
  )}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
