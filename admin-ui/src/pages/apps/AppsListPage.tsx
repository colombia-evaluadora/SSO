import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import {
  useApps,
  useCreateApp,
  useDeleteApp,
  useUpdateApp,
} from "@/hooks/useApps";
import type { AppResponse } from "@/api/types";
import type { AppFormValues } from "@/schemas";
import { AppFormDrawer } from "./AppFormDrawer";

/**
 * Admin CRUD for the App entity (SSO_V2). The 4 binding
 * families (roles/users/routes/microservices) are managed
 * inside the edit drawer via tabs — see
 * {@code AppFormDrawer}. This page owns:
 * <ul>
 *   <li>the row table (5 columns: name, description, created
 *       date, binding counts, actions),</li>
 *   <li>the create/edit drawer state,</li>
 *   <li>the delete confirmation modal.</li>
 * </ul>
 *
 * <p>Behaviour worth flagging:
 * <ul>
 *   <li><b>Edit stays open.</b> After "Guardar cambios" the
 *       drawer remains open so the admin can keep toggling
 *       bindings without re-opening. Close is explicit (X /
 *       backdrop).</li>
 *   <li><b>Create closes.</b> After "Crear" the drawer closes
 *       and the new row appears in the table (the
 *       {@code useApps} query is invalidated by
 *       {@code useCreateApp}).</li>
 *   <li><b>409 from the backend</b> (duplicate name) is
 *       surfaced by the {@code Form} component as a red toast
 *       with the error envelope's {@code code} + {@code message}.</li>
 * </ul>
 */
export function AppsListPage() {
  const apps = useApps();
  const createApp = useCreateApp();
  const updateApp = useUpdateApp();
  const deleteApp = useDeleteApp();
  const toast = useToast();

  const [editing, setEditing] = useState<AppResponse | null>(null);
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<AppResponse | null>(null);
  const [search, setSearch] = useState("");

  const filteredApps = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return apps.data ?? [];
    return (apps.data ?? []).filter(
      (a) =>
        a.name.toLowerCase().includes(q) ||
        (a.description ?? "").toLowerCase().includes(q),
    );
  }, [apps.data, search]);

  async function handleSubmit(values: AppFormValues & { id?: number }) {
    if (values.id) {
      await updateApp.mutateAsync({
        id: values.id,
        name: values.name,
        description: values.description ?? null,
        launchUrl: values.launchUrl ?? null,
      });
      toast.show("App actualizada", "success");
      // drawer stays open on edit; admin keeps working
    } else {
      await createApp.mutateAsync({
        name: values.name,
        description: values.description ?? null,
        launchUrl: values.launchUrl ?? null,
      });
      toast.show("App creada", "success");
      setCreating(false);
    }
  }

  async function confirmDelete() {
    if (!deleting) return;
    await deleteApp.mutateAsync(deleting.id);
    toast.show("App eliminada", "success");
    setDeleting(null);
  }

  const columns: Column<AppResponse>[] = [
    {
      key: "name",
      header: "Nombre",
      render: (a) => (
        <span className="font-medium text-slate-900">{a.name}</span>
      ),
    },
    {
      key: "description",
      header: "Descripción",
      render: (a) =>
        a.description ? (
          <span
            className="inline-block max-w-[16rem] truncate align-middle"
            title={a.description}
          >
            {a.description}
          </span>
        ) : (
          "—"
        ),
    },
    {
      key: "createdDate",
      header: "Creado",
      render: (a) =>
        a.createdDate ? new Date(a.createdDate).toLocaleDateString() : "—",
    },
    {
      key: "bindings",
      header: "Bindings",
      render: (a) => (
        <div className="flex flex-wrap gap-1 text-[10px]">
          <span className="rounded bg-slate-100 px-1.5 py-0.5 text-slate-700">
            Roles · {a.roleIds.length}
          </span>
          <span className="rounded bg-slate-100 px-1.5 py-0.5 text-slate-700">
            Users · {a.userIds.length}
          </span>
          <span className="rounded bg-slate-100 px-1.5 py-0.5 text-slate-700">
            Rutas · {a.routeIds.length}
          </span>
          <span className="rounded bg-slate-100 px-1.5 py-0.5 text-slate-700">
            Micros · {a.microserviceIds.length}
          </span>
        </div>
      ),
    },
    {
      key: "actions",
      header: "",
      align: "right",
      render: (a) => (
        <div className="flex justify-end gap-2">
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setEditing(a)}
            data-testid={`edit-${a.id}`}
          >
            Editar
          </Button>
          <Button
            size="sm"
            variant="danger"
            onClick={() => setDeleting(a)}
            data-testid={`delete-${a.id}`}
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
          <h1 className="text-xl font-semibold text-slate-900">Apps</h1>
          <p className="mt-0.5 text-xs text-slate-500">
            Aplicaciones con sus vinculaciones a roles, usuarios, rutas y
            microservicios.
          </p>
        </div>
        <Button onClick={() => setCreating(true)} data-testid="new-app">
          + Nueva app
        </Button>
      </header>

      <div className="mb-3">
        <SearchInput value={search} onChange={setSearch} placeholder="Buscar app…" />
      </div>

      <Table
        columns={columns}
        rows={filteredApps}
        rowKey={(a) => a.id}
        loading={apps.isLoading}
        empty={
          apps.isError
            ? "No se pudo cargar la lista. ¿sso-admin está UP?"
            : search
              ? "Sin resultados."
              : "Aún no hay apps."
        }
      />

      <AppFormDrawer
        open={creating || editing !== null}
        app={editing}
        onClose={() => {
          setCreating(false);
          setEditing(null);
        }}
        onSubmit={handleSubmit}
      />

      <Modal
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        title="Eliminar app"
        description={
          deleting
            ? `Se eliminará "${deleting.name}" y todas sus asociaciones.`
            : ""
        }
        footer={
          <>
            <Button variant="secondary" onClick={() => setDeleting(null)}>
              Cancelar
            </Button>
            <Button
              variant="danger"
              loading={deleteApp.isPending}
              onClick={() => void confirmDelete()}
              data-testid="app-confirm-delete"
            >
              Eliminar
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          Esta acción no se puede deshacer.
        </p>
      </Modal>
    </section>
  );
}