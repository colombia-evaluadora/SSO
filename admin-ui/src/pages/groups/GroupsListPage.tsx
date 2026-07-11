import { useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, type Column } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import { useCreateGroup, useGroups, useUpdateGroup } from "@/hooks/useGroups";
import type { GroupResponse } from "@/api/types";
import { GroupFormDrawer } from "./GroupFormDrawer";
import type { GroupFormValues } from "@/schemas";

export function GroupsListPage() {
  const groups = useGroups();
  const createGroup = useCreateGroup();
  const updateGroup = useUpdateGroup();
  const toast = useToast();
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<GroupResponse | null>(null);
  const [search, setSearch] = useState("");

  const filteredGroups = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return groups.data ?? [];
    return (groups.data ?? []).filter(
      (g) =>
        g.name.toLowerCase().includes(q) ||
        (g.description ?? "").toLowerCase().includes(q),
    );
  }, [groups.data, search]);

  function closeDrawer() {
    setCreating(false);
    setEditing(null);
  }

  async function handleSubmit(values: GroupFormValues & { id?: number }) {
    if (values.id != null) {
      await updateGroup.mutateAsync(values);
      toast.show("Grupo actualizado", "success");
    } else {
      await createGroup.mutateAsync(values);
      toast.show("Grupo creado", "success");
    }
    closeDrawer();
  }

  const columns: Column<GroupResponse>[] = [
    { key: "name", header: "Nombre", render: (g) => g.name },
    { key: "description", header: "Descripción", render: (g) => g.description || "—" },
    {
      key: "members",
      header: "Miembros",
      align: "right",
      render: (g) => g.memberCount,
    },
    {
      key: "actions",
      header: "",
      align: "right",
      render: (g) => (
        <Button size="sm" variant="secondary" onClick={() => setEditing(g)}>
          Editar
        </Button>
      ),
    },
  ];

  return (
    <section>
      <header className="mb-4 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-slate-900">Grupos</h1>
        <Button onClick={() => setCreating(true)}>+ Nuevo grupo</Button>
      </header>
      <div className="mb-3">
        <SearchInput value={search} onChange={setSearch} placeholder="Buscar grupo…" />
      </div>
      <Table
        columns={columns}
        rows={filteredGroups}
        rowKey={(g) => g.id}
        loading={groups.isLoading}
        empty={search ? "Sin resultados." : "Aún no hay grupos."}
      />
      <GroupFormDrawer
        open={creating || editing !== null}
        group={editing}
        onClose={closeDrawer}
        onSubmit={handleSubmit}
      />
    </section>
  );
}
