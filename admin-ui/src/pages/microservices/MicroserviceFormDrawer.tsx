import { useMemo } from "react";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import {
  microserviceFormSchema,
  type MicroserviceFormValues,
} from "@/schemas";
import type { MicroserviceResponse } from "@/api/types";

interface Props {
  open: boolean;
  microservice: MicroserviceResponse | null;
  onClose: () => void;
  onSubmit: (values: MicroserviceFormValues & { id?: number }) => Promise<void>;
}

/**
 * Form drawer for REST microservice CRUD — the classic gateway
 * routing rule (host + port + path). QUERY-kind services have
 * their own drawer ({@link QueryServiceFormDrawer}) on the Query
 * Services page; the two are deliberately NOT the same component
 * so neither page has to carry the other's fields or logic.
 *
 * <p>`kind` is pinned to "REST" here: the payload always carries
 * it so the shared {@code microserviceFormSchema} validates the
 * REST branch (host/port/path required, JDBC fields ignored).
 */
export function MicroserviceFormDrawer({
  open,
  microservice,
  onClose,
  onSubmit,
}: Props) {
  const initialValues: MicroserviceFormValues = useMemo(
    () => ({
      serviceId: microservice?.serviceId ?? "",
      description: microservice?.description ?? "",
      requestUri: microservice?.requestUri ?? "",
      targetUriPath: microservice?.targetUriPath ?? "",
      targetUrlHost: microservice?.targetUrlHost ?? "",
      targetUrlPort: microservice?.targetUrlPort ?? "",
      kind: "REST",
      // QUERY-only fields kept as empty defaults so the value
      // shape stays MicroserviceFormValues; the schema's REST
      // branch treats them as optional and they never render.
      dialect: "",
      jdbcUrl: "",
      dbUsername: "",
      dbPassword: "",
      poolSize: 10,
      instanceName: "",
    }),
    [microservice],
  );

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={
        microservice
          ? `Editar microservicio: ${microservice.serviceId}`
          : "Nuevo microservicio"
      }
      description="Configura el destino HTTP al que el gateway enrutará las peticiones."
      footer={null}
      width="lg"
    >
      <Form<MicroserviceFormValues>
        initialValues={initialValues}
        validate={(values) => {
          const result = microserviceFormSchema.safeParse(values);
          if (result.success) return {};
          return zodFieldErrors(result.error);
        }}
        onSubmit={async (values) => {
          const payload: MicroserviceFormValues = { ...values, kind: "REST" as const };
          await onSubmit(microservice ? { id: microservice.id, ...payload } : payload);
        }}
        onCancel={onClose}
        submitLabel={microservice ? "Guardar cambios" : "Crear"}
      >
        {({ values, setField, errors }) => (
          <>
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Service ID"
                required
                value={values.serviceId}
                onChange={(e) => setField("serviceId", e.target.value)}
                error={errors.serviceId}
                hint="Identificador único (lowercase, sin espacios)"
              />
              <Input
                label="Request URI"
                required
                value={values.requestUri}
                onChange={(e) => setField("requestUri", e.target.value)}
                error={errors.requestUri}
                hint="Patrón de URI entrante, ej. /api/orders/**"
              />
            </div>
            <div className="h-3" />
            <Input
              label="Descripción"
              value={values.description}
              onChange={(e) => setField("description", e.target.value)}
              error={errors.description}
            />
            <div className="h-3" />
            <div className="grid grid-cols-3 gap-3">
              <Input
                label="Target host"
                required
                value={values.targetUrlHost}
                onChange={(e) => setField("targetUrlHost", e.target.value)}
                error={errors.targetUrlHost}
              />
              <Input
                label="Target port"
                required
                value={values.targetUrlPort}
                onChange={(e) => setField("targetUrlPort", e.target.value)}
                error={errors.targetUrlPort}
              />
              <Input
                label="Target path"
                required
                value={values.targetUriPath}
                onChange={(e) => setField("targetUriPath", e.target.value)}
                error={errors.targetUriPath}
              />
            </div>
          </>
        )}
      </Form>
    </Drawer>
  );
}
