import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import {
  useCreateUser,
  useDeactivateUser,
  useReactivateUser,
  useResendActivation,
  useUpdateUser,
  useUsers,
} from "@/hooks/useUsers";
import type {
  CreateAccountRequest,
  UpdateAccountRequest,
  UserResponse,
} from "@/api/types";
import { UserFormDrawer } from "./UserFormDrawer";

const STATUS_BADGE: Record<UserResponse["status"], { label: string; className: string }> = {
  PENDING_ACTIVATION: {
    label: "Pendiente de activación",
    className: "bg-amber-100 text-amber-800",
  },
  ACTIVE: { label: "Activo", className: "bg-emerald-100 text-emerald-800" },
  INACTIVE: { label: "Inactivo", className: "bg-slate-200 text-slate-700" },
};

export function UsersListPage() {
  const users = useUsers();
  const createUser = useCreateUser();
  const updateUser = useUpdateUser();
  const resendActivation = useResendActivation();
  const deactivateUser = useDeactivateUser();
  const reactivateUser = useReactivateUser();
  const toast = useToast();
  const [editing, setEditing] = useState<UserResponse | null>(null);
  const [creating, setCreating] = useState(false);
  const [search, setSearch] = useState("");

  const filteredUsers = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return users.data ?? [];
    return (users.data ?? []).filter(
      (u) =>
        u.email.toLowerCase().includes(q) || u.fullName.toLowerCase().includes(q),
    );
  }, [users.data, search]);

  async function handleResendActivation(u: UserResponse) {
    await resendActivation.mutateAsync(u.id);
    toast.show(`Correo de activación reenviado a ${u.email}`, "success");
  }

  async function handleDeactivate(u: UserResponse) {
    if (!window.confirm(`¿Inactivar a ${u.email}? No podrá volver a iniciar sesión.`)) {
      return;
    }
    await deactivateUser.mutateAsync({ userId: u.id });
    toast.show(`Usuario ${u.email} inactivado`, "success");
  }

  async function handleReactivate(u: UserResponse) {
    await reactivateUser.mutateAsync(u.id);
    toast.show(`Usuario ${u.email} reactivado`, "success");
  }

  async function handleSubmit(values: CreateAccountRequest | UpdateAccountRequest) {
    if ("id" in values) {
      await updateUser.mutateAsync(values);
      toast.show("Usuario actualizado", "success");
    } else {
      // No password — the user sets theirs at the activation
      // link in the email we send them.
      await createUser.mutateAsync(values);
      toast.show(
        "Usuario creado. Se le ha enviado un correo para activar la cuenta.",
        "success",
      );
    }
    setEditing(null);
    setCreating(false);
  }

  const columns: Column<UserResponse>[] = [
    // Post-V12 the table renders `email` where `Usuario` used
    // to go — email IS the login identifier now and the
    // `UserResponse` record no longer carries a separate
    // `username` slot. The render falls back to `fullName` when
    // the email is empty so freshly-seeded rows that haven't
    // hydrated a name yet still show a readable handle.
    { key: "email", header: "Email", render: (u) => u.email },
    { key: "fullName", header: "Nombre", render: (u) => u.fullName },
    {
      key: "status",
      header: "Estado",
      render: (u) => {
        const badge = STATUS_BADGE[u.status];
        return (
          <span className={`rounded px-2 py-0.5 text-xs ${badge.className}`}>
            {badge.label}
          </span>
        );
      },
    },
    {
      key: "ldap",
      header: "Fuente",
      render: (u) => (u.ldap ? "LDAP" : "Local"),
    },
    {
      key: "roles",
      header: "Roles",
      render: (u) =>
        u.roleNames.length > 0 ? u.roleNames.join(", ") : "—",
    },
    {
      key: "actions",
      header: "",
      align: "right",
      render: (u) => (
        <div className="flex justify-end gap-2">
          {u.status === "PENDING_ACTIVATION" && (
            <Button
              size="sm"
              variant="secondary"
              onClick={() => void handleResendActivation(u)}
            >
              Reenviar activación
            </Button>
          )}
          {u.status === "ACTIVE" && (
            <Button size="sm" variant="secondary" onClick={() => void handleDeactivate(u)}>
              Inactivar
            </Button>
          )}
          {u.status === "INACTIVE" && (
            <Button size="sm" variant="secondary" onClick={() => void handleReactivate(u)}>
              Reactivar
            </Button>
          )}
          <Button size="sm" variant="secondary" onClick={() => setEditing(u)}>
            Editar
          </Button>
        </div>
      ),
    },
  ];

  return (
    <section>
      <header className="mb-4 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-slate-900">Usuarios</h1>
        <Button onClick={() => setCreating(true)}>+ Nuevo usuario</Button>
      </header>

      <div className="mb-3">
        <SearchInput value={search} onChange={setSearch} placeholder="Buscar por email o nombre…" />
      </div>

      <Table
        columns={columns}
        rows={filteredUsers}
        rowKey={(u) => u.id}
        loading={users.isLoading}
        empty={search ? "Sin resultados." : "Aún no hay usuarios."}
      />

      <UserFormDrawer
        open={creating || editing !== null}
        user={editing}
        onClose={() => {
          setCreating(false);
          setEditing(null);
        }}
        onSubmit={handleSubmit}
      />
    </section>
  );
}
