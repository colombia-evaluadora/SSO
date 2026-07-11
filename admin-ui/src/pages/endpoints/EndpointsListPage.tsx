import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import {
  useCreateEndpoint,
  useDeleteEndpoint,
  useEndpoints,
  useUpdateEndpoint,
} from "@/hooks/useEndpoints";
import type { EndpointResponse } from "@/api/types";
import { EndpointFormDrawer } from "./EndpointFormDrawer";
import type { EndpointFormValues } from "@/schemas";

export function EndpointsListPage() {
  const endpoints = useEndpoints();
  const createEp = useCreateEndpoint();
  const updateEp = useUpdateEndpoint();
  const deleteEp = useDeleteEndpoint();
  const toast = useToast();
  const [editing, setEditing] = useState<EndpointResponse | null>(null);
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<EndpointResponse | null>(null);
  const [search, setSearch] = useState("");

  const filteredEndpoints = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return endpoints.data ?? [];
    return (endpoints.data ?? []).filter(
      (e) =>
        e.method.toLowerCase().includes(q) ||
        e.path.toLowerCase().includes(q) ||
        (e.description ?? "").toLowerCase().includes(q),
    );
  }, [endpoints.data, search]);

  async function handleSubmit(values: EndpointFormValues & { id?: number }) {
    if (values.id) {
      await updateEp.mutateAsync({
        id: values.id,
        method: values.method,
        path: values.path,
        description: values.description,
        numberParams: values.numberParams,
      });
      toast.show("Endpoint actualizado", "success");
    } else {
      await createEp.mutateAsync({
        method: values.method,
        path: values.path,
        description: values.description,
        numberParams: values.numberParams,
      });
      toast.show("Endpoint creado", "success");
    }
    setEditing(null);
    setCreating(false);
  }

  async function confirmDelete() {
    if (!deleting) return;
    await deleteEp.mutateAsync(deleting.id);
    toast.show("Endpoint eliminado", "success");
    setDeleting(null);
  }

  const columns: Column<EndpointResponse>[] = [
    {
      key: "method",
      header: "Método",
      width: "6rem",
      render: (e) => (
        <span
          className={[
            "inline-block rounded px-2 py-0.5 text-xs font-semibold",
            e.method === "GET" && "bg-sky-100 text-sky-800",
            e.method === "POST" && "bg-emerald-100 text-emerald-800",
            e.method === "PUT" && "bg-amber-100 text-amber-800",
            e.method === "DELETE" && "bg-red-100 text-red-800",
            e.method === "PATCH" && "bg-violet-100 text-violet-800",
          ]
            .filter(Boolean)
            .join(" ")}
        >
          {e.method}
        </span>
      ),
    },
    { key: "path", header: "Path", render: (e) => <code className="text-xs">{e.path}</code> },
    { key: "description", header: "Descripción", render: (e) => e.description || "—" },
    {
      key: "params",
      header: "Params",
      align: "right",
      render: (e) => e.numberParams,
    },
    {
      key: "micros",
      header: "Micros",
      align: "right",
      render: (e) => e.microserviceIds.length,
    },
    {
      key: "actions",
      header: "",
      align: "right",
      render: (e) => (
        <div className="flex justify-end gap-2">
          <Button size="sm" variant="secondary" onClick={() => setEditing(e)}>
            Editar
          </Button>
          <Button size="sm" variant="danger" onClick={() => setDeleting(e)}>
            Eliminar
          </Button>
        </div>
      ),
    },
  ];

  return (
    <section>
      <header className="mb-4 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-slate-900">Endpoints</h1>
        <Button onClick={() => setCreating(true)}>+ Nuevo endpoint</Button>
      </header>
      <div className="mb-3">
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="Buscar por método, path o descripción…"
        />
      </div>
      <Table
        columns={columns}
        rows={filteredEndpoints}
        rowKey={(e) => e.id}
        loading={endpoints.isLoading}
        empty={search ? "Sin resultados." : "Aún no hay endpoints."}
      />
      <EndpointFormDrawer
        open={creating || editing !== null}
        endpoint={editing}
        onClose={() => {
          setCreating(false);
          setEditing(null);
        }}
        onSubmit={handleSubmit}
      />
      <Modal
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        title="Eliminar endpoint"
        description={`¿Seguro que quieres eliminar "${deleting?.method} ${deleting?.path}"?`}
        footer={
          <>
            <Button variant="secondary" onClick={() => setDeleting(null)}>
              Cancelar
            </Button>
            <Button
              variant="danger"
              loading={deleteEp.isPending}
              onClick={() => void confirmDelete()}
            >
              Eliminar
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          Se desvincularán los microservicios y roles asociados.
        </p>
      </Modal>
    </section>
  );
}
