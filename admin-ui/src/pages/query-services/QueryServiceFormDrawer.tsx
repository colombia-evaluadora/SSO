import { useMemo } from "react";
import { useMutation } from "@tanstack/react-query";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import {
  microserviceFormSchema,
  QUERY_DIALECTS,
  type MicroserviceFormValues,
} from "@/schemas";
import type {
  MicroserviceResponse,
  MicroserviceTestConnectionRequest,
  MicroserviceTestConnectionResponse,
} from "@/api/types";
import { microservicesApi } from "@/api/endpoints";

interface Props {
  open: boolean;
  microservice: MicroserviceResponse | null;
  onClose: () => void;
  onSubmit: (values: MicroserviceFormValues & { id?: number }) => Promise<void>;
}

/**
 * Form drawer for QUERY-service CRUD — the JDBC metadata block.
 * The backend creates the row, calls the provisioner sidecar to
 * spin up a `query-service-<instance>` container, and waits for
 * Eureka before returning; the drawer stays open with a spinner
 * for that round-trip.
 *
 * <p>Deliberately separate from {@link MicroserviceFormDrawer}
 * (REST): each page owns exactly one drawer so neither carries
 * the other's fields. `kind` is pinned to "QUERY" so the shared
 * {@code microserviceFormSchema} validates the JDBC branch.
 */
export function QueryServiceFormDrawer({
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
      // REST-only fields kept as empty defaults so the value shape
      // stays MicroserviceFormValues; the schema's QUERY branch
      // treats them as optional and they never render here.
      targetUriPath: microservice?.targetUriPath ?? "",
      targetUrlHost: microservice?.targetUrlHost ?? "",
      targetUrlPort: microservice?.targetUrlPort ?? "",
      kind: "QUERY",
      dialect: microservice?.dialect ?? "",
      jdbcUrl: microservice?.jdbcUrl ?? "",
      dbUsername: microservice?.dbUsername ?? "",
      dbPassword: microservice?.dbPassword ?? "",
      poolSize: microservice?.poolSize ?? 10,
      instanceName: microservice?.instanceName ?? "",
    }),
    [microservice],
  );

  // Sonda JDBC sin persistencia. useMutation propio para que el
  // ciclo de vida del banner sea independiente del "Crear/Guardar".
  const testMutation = useMutation<
    MicroserviceTestConnectionResponse,
    Error,
    MicroserviceTestConnectionRequest
  >({
    mutationFn: (body) => microservicesApi.testConnection(body),
  });

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={
        microservice
          ? `Editar query service: ${microservice.serviceId}`
          : "Nuevo query service"
      }
      description="Configura los datos JDBC y el provisioner levantará un contenedor query-service."
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
          const payload: MicroserviceFormValues = { ...values, kind: "QUERY" as const };
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
                hint="Patrón de URI entrante, ej. /api/queries/**"
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

            <div className="grid grid-cols-2 gap-3">
              <DialectSelect
                value={values.dialect}
                onChange={(v) => setField("dialect", v)}
                error={errors.dialect}
              />
              <Input
                label="Instance name"
                required
                value={values.instanceName}
                onChange={(e) => setField("instanceName", e.target.value)}
                error={errors.instanceName}
                hint="Sufijo del service-id en Eureka. ej. 'oracle-dev'"
              />
            </div>
            <div className="h-3" />
            <Input
              label="JDBC URL"
              required
              value={values.jdbcUrl}
              onChange={(e) => setField("jdbcUrl", e.target.value)}
              error={errors.jdbcUrl}
              hint="ej. jdbc:postgresql://host:5432/db"
            />
            <div className="h-3" />
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="DB username"
                required
                value={values.dbUsername}
                onChange={(e) => setField("dbUsername", e.target.value)}
                error={errors.dbUsername}
              />
              <Input
                label="DB password"
                type="password"
                value={values.dbPassword}
                onChange={(e) => setField("dbPassword", e.target.value)}
                error={errors.dbPassword}
                hint="Solo se envía al provisioner; nunca vuelve al cliente."
              />
            </div>
            <div className="h-3" />
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="HikariCP pool size"
                type="number"
                min={1}
                max={1000}
                value={String(values.poolSize ?? 10)}
                onChange={(e) => setField("poolSize", Number(e.target.value))}
                error={errors.poolSize}
              />
            </div>
            <div className="h-4" />
            {/* Test-connection probe: dispara el endpoint sin
                persistir nada — banner inline con éxito/fallo y
                latencia. type="button" para no confundir con el
                submit del Form. */}
            <div className="flex items-start gap-3">
              <Button
                type="button"
                variant="secondary"
                size="sm"
                disabled={!values.jdbcUrl || testMutation.isPending}
                loading={testMutation.isPending}
                onClick={() =>
                  testMutation.mutate({
                    jdbcUrl: values.jdbcUrl,
                    dbUsername: values.dbUsername,
                    dbPassword: values.dbPassword,
                    dialect: values.dialect,
                  })
                }
              >
                Probar conexión
              </Button>
              {testMutation.data && (
                <div
                  role="status"
                  className={`flex-1 rounded border px-3 py-2 text-sm ${
                    testMutation.data.ok
                      ? "border-emerald-200 bg-emerald-50 text-emerald-800"
                      : "border-red-200 bg-red-50 text-red-800"
                  }`}
                >
                  <span aria-hidden="true">
                    {testMutation.data.ok ? "✓ " : "✗ "}
                  </span>
                  {testMutation.data.message}
                  {testMutation.data.ok && (
                    <span className="ml-2 text-xs opacity-70">
                      ({testMutation.data.latencyMs} ms)
                    </span>
                  )}
                </div>
              )}
              {testMutation.error && (
                <div
                  role="alert"
                  className="flex-1 rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
                >
                  <span aria-hidden="true">✗ </span>
                  {testMutation.error.message}
                </div>
              )}
            </div>
          </>
        )}
      </Form>
    </Drawer>
  );
}

/**
 * Native {@code <select>} for the dialect. Small enough that a
 * wrapper around the platform control is fine.
 */
function DialectSelect({
  value,
  onChange,
  error,
}: {
  value: string;
  onChange: (v: string) => void;
  error?: string | undefined;
}) {
  const id = `dialect-${Math.random().toString(36).slice(2)}`;
  return (
    <div>
      <label
        htmlFor={id}
        className="mb-1 block text-sm font-medium text-slate-700"
      >
        Dialecto
        <span aria-hidden="true" className="ml-0.5 text-red-600">*</span>
      </label>
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        aria-invalid={error ? true : undefined}
        className={[
          "w-full rounded border bg-white px-3 py-2 text-sm text-slate-900",
          "outline-none transition-colors",
          error
            ? "border-red-400 focus:border-red-500 focus:ring-1 focus:ring-red-500"
            : "border-slate-300 focus:border-sky-500 focus:ring-1 focus:ring-sky-500",
        ].join(" ")}
      >
        <option value="" disabled>Selecciona…</option>
        {QUERY_DIALECTS.map((d) => (
          <option key={d} value={d}>{d}</option>
        ))}
      </select>
      {error ? (
        <p role="alert" className="mt-1 text-xs text-red-600">{error}</p>
      ) : null}
    </div>
  );
}
