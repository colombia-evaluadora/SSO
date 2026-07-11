import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import {
  useCreateMicroservice,
  useDeleteMicroservice,
  useMicroservices,
  useUpdateMicroservice,
} from "@/hooks/useMicroservices";
import type { MicroserviceResponse } from "@/api/types";
import { MicroserviceFormDrawer } from "./MicroserviceFormDrawer";
import { QueryServicesSection } from "@/pages/query-services/QueryServicesSection";
import type { MicroserviceFormValues } from "@/schemas";

/**
 * The Microservicios page: REST microservices (the classic gateway
 * routing rules) up top, then the QUERY-kind services (JDBC-backed
 * query-service containers, with their own CRUD + ops) in the
 * {@link QueryServicesSection} below. The two tables stay separate —
 * each has its own drawer so neither has to branch on `kind` — but
 * share one page instead of a standalone /admin/query-services route.
 */
export function MicroservicesListPage() {
  const microservices = useMicroservices();
  const createMs = useCreateMicroservice();
  const updateMs = useUpdateMicroservice();
  const deleteMs = useDeleteMicroservice();
  const toast = useToast();
  const [editing, setEditing] = useState<MicroserviceResponse | null>(null);
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<MicroserviceResponse | null>(null);
  const [search, setSearch] = useState("");

  // REST rows only; QUERY services are managed in the section below.
  const restRows = useMemo(
    () => (microservices.data ?? []).filter((m) => m.kind === "REST"),
    [microservices.data],
  );

  const filteredMicroservices = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return restRows;
    return restRows.filter(
      (m) =>
        m.serviceId.toLowerCase().includes(q) || (m.description ?? "").toLowerCase().includes(q),
    );
  }, [restRows, search]);

  async function handleSubmit(values: MicroserviceFormValues & { id?: number }) {
    try {
      if (values.id) {
        await updateMs.mutateAsync(values as Parameters<typeof updateMs.mutateAsync>[0]);
        toast.show("Microservicio actualizado", "success");
      } else {
        await createMs.mutateAsync(values as Parameters<typeof createMs.mutateAsync>[0]);
        toast.show("Microservicio creado", "success");
      }
      setEditing(null);
      setCreating(false);
    } catch (err) {
      // The Form<T> wrapper already toasts the error; we
      // just keep the drawer open so the user can fix it.
      console.error("microservice save failed", err);
    }
  }

  async function confirmDelete() {
    if (!deleting) return;
    await deleteMs.mutateAsync(deleting.id);
    toast.show("Microservicio eliminado", "success");
    setDeleting(null);
  }

  const columns: Column<MicroserviceResponse>[] = [
    { key: "serviceId", header: "Service ID", render: (m) => m.serviceId },
    {
      key: "requestUri",
      header: "Request URI",
      render: (m) => m.requestUri,
    },
    {
      key: "target",
      header: "Target",
      render: (m) => `${m.targetUrlHost}:${m.targetUrlPort}${m.targetUriPath}`,
    },
    {
      key: "description",
      header: "Descripción",
      render: (m) => m.description || "—",
    },
    {
      key: "actions",
      header: "",
      align: "right",
      render: (m) => (
        <div className="flex justify-end gap-2">
          <Button size="sm" variant="secondary" onClick={() => setEditing(m)}>
            Editar
          </Button>
          <Button size="sm" variant="danger" onClick={() => setDeleting(m)}>
            Eliminar
          </Button>
        </div>
      ),
    },
  ];

  return (
    <div>
      <section>
        <header className="mb-4 flex items-center justify-between">
          <h1 className="text-xl font-semibold text-slate-900">Microservicios</h1>
          <Button onClick={() => setCreating(true)}>+ Nuevo microservicio</Button>
        </header>
        <div className="mb-3">
          <SearchInput
            value={search}
            onChange={setSearch}
            placeholder="Buscar por service ID o descripción…"
          />
        </div>
        <Table
          columns={columns}
          rows={filteredMicroservices}
          rowKey={(m) => m.id}
          loading={microservices.isLoading}
          empty={search ? "Sin resultados." : "Aún no hay microservicios REST."}
        />
        <MicroserviceFormDrawer
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
          title="Eliminar microservicio"
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
            Si hay endpoints vinculados, el backend podría rechazar la operación.
          </p>
        </Modal>
      </section>
      <QueryServicesSection />
    </div>
  );
}
