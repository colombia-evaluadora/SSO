import { useMemo } from "react";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import { queryFormSchema, type QueryFormValues } from "@/schemas";
import { useMicroservices } from "@/hooks/useMicroservices";
import type { QueryAdminResponse } from "@/api/types";

interface Props {
  open: boolean;
  query: QueryAdminResponse | null;
  onClose: () => void;
  onSubmit: (values: QueryFormValues & { id?: number }) => Promise<void>;
}

/**
 * Form drawer for the Queries Catalog admin CRUD. The two
 * non-trivial controls are:
 * <ul>
 *   <li>{@code microserviceId} — a {@code <select>} populated
 *       from {@link useMicroservices} filtered to
 *       {@code kind=QUERY}. The {@code queryFormSchema}
 *       accepts {@code null} (treated as "Sin binding —
 *       query global"); the backend's
 *       {@link com.co.eurekatic.ssoadmin.service.QueryAdminService}
 *       rejects any other null/blank state with 422.</li>
 *   <li>{@code query} — a multi-line text input for the raw
 *       SQL. Parameter binding uses {@code :placeholder}
 *       tokens the catalog passes straight through to the
 *       JDBC driver; the form does NOT try to parse or
 *       validate them.</li>
 * </ul>
 *
 * <p>Detail / action / style are surfaced as textareas (json
 * opaque to the catalog endpoint) collapsed under a
 * {@code <details>} toggle so the SQL editor stays uncluttered
 * by metadata most admins never touch.
 */
export function QueryFormDrawer({ open, query, onClose, onSubmit }: Props) {
  const services = useMicroservices();

  const initialValues: QueryFormValues = useMemo(
    () => ({
      uuid: query?.uuid ?? "",
      query: query?.query ?? "",
      type: query?.type ?? "",
      publicEnd: query?.publicEnd ?? false,
      captcha: query?.captcha ?? false,
      detail: query?.detail ?? "",
      action: query?.action ?? "",
      style: query?.style ?? "",
      microserviceId: query?.microserviceId ?? null,
    }),
    [query],
  );

  const queryInstances = useMemo(
    () => (services.data ?? []).filter((m) => m.kind === "QUERY"),
    [services.data],
  );

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={query ? `Editar query: ${query.uuid}` : "Nuevo query"}
      description="Define el SQL y la metadata. El binding al microservicio decide qué query-service-<instance> lo sirve."
      footer={null}
      width="lg"
    >
      <Form<QueryFormValues>
        initialValues={initialValues}
        validate={(values) => {
          const result = queryFormSchema.safeParse(values);
          if (result.success) return {};
          return zodFieldErrors(result.error);
        }}
        onSubmit={async (values) => {
          await onSubmit(query ? { id: query.id, ...values } : values);
        }}
        onCancel={onClose}
        submitLabel={query ? "Guardar cambios" : "Crear"}
      >
        {({ values, setField, errors }) => (
          <>
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="UUID"
                required
                value={values.uuid}
                onChange={(e) => setField("uuid", e.target.value)}
                error={errors.uuid}
                hint="Handle público para el consumidor (letras, números, _ y -)"
              />
              <Input
                label="Tipo"
                value={values.type}
                onChange={(e) => setField("type", e.target.value)}
                error={errors.type}
                hint="Etiqueta opcional (QUERY, CHART, …)"
              />
            </div>
            <div className="h-3" />
            <label className="block text-sm">
              <span className="mb-1 block font-medium text-slate-700">
                SQL<span className="ml-0.5 text-red-600">*</span>
              </span>
              <textarea
                value={values.query}
                onChange={(e) => setField("query", e.target.value)}
                rows={6}
                className={[
                  "w-full rounded border bg-white px-3 py-2 font-mono text-xs text-slate-900 outline-none focus:ring-1",
                  errors.query
                    ? "border-red-400 focus:border-red-500 focus:ring-red-500"
                    : "border-slate-300 focus:border-sky-500 focus:ring-sky-500",
                ].join(" ")}
                aria-invalid={errors.query ? true : undefined}
                placeholder="SELECT id, email FROM sso_user WHERE username = :username"
              />
              {errors.query ? (
                <p role="alert" className="mt-1 text-xs text-red-600">
                  {errors.query}
                </p>
              ) : null}
              <p className="mt-1 text-[11px] text-slate-500">
                Bindings con <code>:placeholder</code> se resuelven en el
                query-service vía <code>MapSqlParameterSource</code>.
              </p>
            </label>
            <div className="h-3" />
            <div>
              <label
                htmlFor="query-microservice"
                className="mb-1 block text-sm font-medium text-slate-700"
              >
                Microservicio (kind=QUERY)
              </label>
              <select
                id="query-microservice"
                value={
                  values.microserviceId == null ? "" : String(values.microserviceId)
                }
                onChange={(e) =>
                  setField(
                    "microserviceId",
                    e.target.value === "" ? null : Number(e.target.value),
                  )
                }
                className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
              >
                <option value="">Sin binding (global)</option>
                {queryInstances.map((m) => (
                  <option key={m.id} value={String(m.id)}>
                    #{m.id} · {m.instanceName ?? m.serviceId}
                    {m.dialect ? ` (${m.dialect})` : ""}
                  </option>
                ))}
              </select>
              {queryInstances.length === 0 && !services.isLoading ? (
                <p className="mt-1 text-[11px] text-slate-500">
                  No hay microservicios QUERY aprovisionados aún.
                </p>
              ) : null}
            </div>
            <div className="h-3" />
            <div className="flex items-center gap-6">
              <label className="flex items-center gap-2 text-sm text-slate-700">
                <input
                  type="checkbox"
                  checked={values.publicEnd}
                  onChange={(e) => setField("publicEnd", e.target.checked)}
                  className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
                />
                Endpoint público
              </label>
              <label className="flex items-center gap-2 text-sm text-slate-700">
                <input
                  type="checkbox"
                  checked={values.captcha}
                  onChange={(e) => setField("captcha", e.target.checked)}
                  className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
                />
                Requiere captcha
              </label>
            </div>
            <div className="h-3" />
            <details className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs">
              <summary className="cursor-pointer font-medium text-slate-700">
                Metadata UI (detail / action / style)
              </summary>
              <div className="mt-2 grid gap-3">
                <label className="block">
                  <span className="mb-1 block font-medium text-slate-700">detail</span>
                  <textarea
                    value={values.detail}
                    onChange={(e) => setField("detail", e.target.value)}
                    rows={3}
                    className="w-full rounded border border-slate-300 bg-white px-3 py-2 font-mono text-[11px] outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                    placeholder='{"fields":[{"key":"username","label":"Usuario"}]}'
                  />
                </label>
                <label className="block">
                  <span className="mb-1 block font-medium text-slate-700">action</span>
                  <textarea
                    value={values.action}
                    onChange={(e) => setField("action", e.target.value)}
                    rows={2}
                    className="w-full rounded border border-slate-300 bg-white px-3 py-2 font-mono text-[11px] outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                  />
                </label>
                <label className="block">
                  <span className="mb-1 block font-medium text-slate-700">style</span>
                  <textarea
                    value={values.style}
                    onChange={(e) => setField("style", e.target.value)}
                    rows={2}
                    className="w-full rounded border border-slate-300 bg-white px-3 py-2 font-mono text-[11px] outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                  />
                </label>
              </div>
            </details>
            <div className="h-3" />
            <p className="text-[11px] text-slate-500">
              Los bindings a roles se gestionan en el modal "Roles" después de guardar
              (mismo patrón que Endpoints).
            </p>
          </>
        )}
      </Form>
    </Drawer>
  );
}
