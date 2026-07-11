import { useMemo } from "react";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import { Tabs, type TabItem } from "@/components/ui/Tabs";
import { BindingTab } from "@/components/ui/BindingTab";
import { groupFormSchema, type GroupFormValues } from "@/schemas";
import type { GroupResponse, GroupRoleChecked } from "@/api/types";
import {
  useBindGroupRole,
  useGroupRolesChecked,
  useUnbindGroupRole,
} from "@/hooks/useGroups";

/**
 * Drawer for create + edit of a Group. Mirrors AppFormDrawer's
 * tabbed pattern: a General tab (name/description, the only
 * tab that submits a CRUD payload) plus a Roles tab (a
 * checked-listing of roles with a Vincular/Desvincular toggle
 * per row, backed by the shared {@code BindingTab} primitive).
 * The Roles tab only makes sense for an existing group — it's
 * disabled (with a hint) until the group has been saved.
 */
interface Props {
  open: boolean;
  group?: GroupResponse | null;
  onClose: () => void;
  onSubmit: (values: GroupFormValues & { id?: number }) => Promise<void>;
}

export function GroupFormDrawer({ open, group, onClose, onSubmit }: Props) {
  const initialValues: GroupFormValues = useMemo(
    () => ({
      name: group?.name ?? "",
      description: group?.description ?? "",
    }),
    [group],
  );

  const tabs: TabItem[] = [
    {
      key: "general",
      label: "General",
      content: (
        <GeneralTab
          group={group ?? null}
          initialValues={initialValues}
          onSubmit={onSubmit}
          onClose={onClose}
        />
      ),
    },
    {
      key: "roles",
      label: "Roles",
      content: group ? <RolesTab groupId={group.id} /> : <DisabledTabHint />,
    },
  ];

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={group ? `Editar grupo: ${group.name}` : "Nuevo grupo"}
      description="Los grupos se usan para organizar usuarios."
      footer={null}
    >
      <Tabs tabs={tabs} ariaLabel="Secciones del formulario de grupo" />
    </Drawer>
  );
}

/* ====================== General tab ====================== */

interface GeneralTabProps {
  group: GroupResponse | null;
  initialValues: GroupFormValues;
  onSubmit: (values: GroupFormValues & { id?: number }) => Promise<void>;
  onClose: () => void;
}

function GeneralTab({ group, initialValues, onSubmit, onClose }: GeneralTabProps) {
  return (
    <Form<GroupFormValues>
      initialValues={initialValues}
      validate={(values) => {
        const result = groupFormSchema.safeParse(values);
        if (result.success) return {};
        return zodFieldErrors(result.error);
      }}
      onSubmit={async (values) => {
        await onSubmit(group ? { id: group.id, ...values } : values);
      }}
      onCancel={onClose}
      submitLabel={group ? "Guardar cambios" : "Crear grupo"}
    >
      {({ values, setField, errors }) => (
        <>
          <Input
            label="Nombre"
            required
            value={values.name}
            onChange={(e) => setField("name", e.target.value)}
            error={errors.name}
          />
          <div className="h-3" />
          <Input
            label="Descripción"
            value={values.description}
            onChange={(e) => setField("description", e.target.value)}
            error={errors.description}
          />
        </>
      )}
    </Form>
  );
}

function DisabledTabHint() {
  return (
    <p className="text-sm text-slate-500">
      Guarda el grupo primero para habilitar la gestión de vinculaciones.
    </p>
  );
}

/* ====================== Roles tab ====================== */

function RolesTab({ groupId }: { groupId: number }) {
  const roles = useGroupRolesChecked(groupId);
  const bind = useBindGroupRole();
  const unbind = useUnbindGroupRole();
  const pending = bind.isPending || unbind.isPending;
  return (
    <BindingTab<GroupRoleChecked>
      entityId={groupId}
      listTestIdPrefix="group-bindings"
      data={roles.data}
      isLoading={roles.isLoading}
      isPending={pending}
      emptyText="No hay roles creados."
      toggleIdPrefix="role-toggle"
      searchPlaceholder="Buscar rol…"
      getRowLabel={(r) => r.name}
      getRowId={(r) => r.roleId}
      getRowChecked={(r) => r.checked}
      onToggle={(roleId, checked) => {
        if (checked) {
          void unbind.mutateAsync({ id: groupId, roleId });
        } else {
          void bind.mutateAsync({ id: groupId, roleId });
        }
      }}
      renderRow={(r) => r.name}
    />
  );
}
