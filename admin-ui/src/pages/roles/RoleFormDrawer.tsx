import { useMemo } from "react";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import { roleFormSchema, type RoleFormValues } from "@/schemas";
import type { RoleResponse } from "@/api/types";

interface Props {
  open: boolean;
  role: RoleResponse | null;
  onClose: () => void;
  onSubmit: (values: RoleFormValues & { id?: number }) => Promise<void>;
}

export function RoleFormDrawer({ open, role, onClose, onSubmit }: Props) {
  const initialValues: RoleFormValues = useMemo(
    () => ({
      name: role?.name ?? "",
      description: role?.description ?? "",
    }),
    [role],
  );

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={role ? `Editar rol: ${role.name}` : "Nuevo rol"}
      description="Define un nombre único y una descripción opcional."
      footer={null}
    >
      <Form<RoleFormValues>
        initialValues={initialValues}
        validate={(values) => {
          const result = roleFormSchema.safeParse(values);
          if (result.success) return {};
          return zodFieldErrors(result.error);
        }}
        onSubmit={async (values) => {
          await onSubmit(role ? { id: role.id, ...values } : values);
        }}
        onCancel={onClose}
        submitLabel={role ? "Guardar cambios" : "Crear rol"}
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
    </Drawer>
  );
}
