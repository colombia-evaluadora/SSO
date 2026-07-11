import { useMemo } from "react";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import { Tabs, type TabItem } from "@/components/ui/Tabs";
import { BindingTab, type BulkAction } from "@/components/ui/BindingTab";
import { appFormSchema, type AppFormValues } from "@/schemas";
import type {
  AppMicroserviceChecked,
  AppResponse,
  AppRoleChecked,
  AppRouteChecked,
  AppUserChecked,
} from "@/api/types";
import {
  useAppMicroservicesChecked,
  useAppRolesChecked,
  useAppRoutesChecked,
  useAppUsersChecked,
  useBindAppMicroservice,
  useBindAppRole,
  useBindAppRoute,
  useBindAppUser,
  useUnbindAppMicroservice,
  useUnbindAppRole,
  useUnbindAppRoute,
  useUnbindAppUser,
} from "@/hooks/useApps";

/**
 * Drawer for create + edit of an App. Hosts 5 tabs:
 * <ol>
 *   <li><b>General</b> — name + description, the only tab that
 *       submits a CRUD payload. Uses the project's hand-rolled
 *       {@code Form} + zod.</li>
 *   <li><b>Roles / Usuarios / Rutas / Microservicios</b> —
 *       checked-listings with one Vincular/Desvincular toggle
 *       per row. Each toggle is one HTTP round-trip (matches
 *       the {@code RolesBindingModal} pattern in
 *       {@code QueriesAdminPage.tsx}). Available only in edit
 *       mode (an app must exist before it can be bound).</li>
 * </ol>
 *
 * <p>The drawer does NOT close after "Guardar cambios" in
 * edit mode — the admin usually wants to keep toggling
 * bindings without re-opening. Close is explicit (X button or
 * backdrop).
 */
interface Props {
  open: boolean;
  app: AppResponse | null;
  onClose: () => void;
  onSubmit: (values: AppFormValues & { id?: number }) => Promise<void>;
}

export function AppFormDrawer({ open, app, onClose, onSubmit }: Props) {
  const initialValues: AppFormValues = useMemo(
    () => ({
      name: app?.name ?? "",
      description: app?.description ?? "",
      launchUrl: app?.launchUrl ?? "",
    }),
    [app],
  );

  const tabs: TabItem[] = [
    {
      key: "general",
      label: "General",
      content: (
        <GeneralTab
          app={app}
          initialValues={initialValues}
          onSubmit={onSubmit}
          onClose={onClose}
        />
      ),
    },
    {
      key: "roles",
      label: "Roles",
      content: app ? <RolesTab appId={app.id} /> : <DisabledTabHint />,
    },
    {
      key: "users",
      label: "Usuarios",
      content: app ? <UsersTab appId={app.id} /> : <DisabledTabHint />,
    },
    {
      key: "routes",
      label: "Rutas",
      content: app ? <RoutesTab appId={app.id} /> : <DisabledTabHint />,
    },
    {
      key: "microservices",
      label: "Microservicios",
      content: app ? (
        <MicroservicesTab appId={app.id} />
      ) : (
        <DisabledTabHint />
      ),
    },
  ];

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={app ? `Editar app: ${app.name}` : "Nueva app"}
      description="Define nombre/descripción y vincula entidades permitidas."
      footer={null}
      width="lg"
    >
      <Tabs tabs={tabs} ariaLabel="Secciones del formulario de App" />
    </Drawer>
  );
}

/* ====================== General tab ====================== */

interface GeneralTabProps {
  app: AppResponse | null;
  initialValues: AppFormValues;
  onSubmit: (values: AppFormValues & { id?: number }) => Promise<void>;
  onClose: () => void;
}

function GeneralTab({ app, initialValues, onSubmit, onClose }: GeneralTabProps) {
  return (
    <Form<AppFormValues>
      initialValues={initialValues}
      validate={(values) => {
        const result = appFormSchema.safeParse(values);
        if (result.success) return {};
        return zodFieldErrors(result.error);
      }}
      onSubmit={async (values) => {
        await onSubmit(app ? { id: app.id, ...values } : values);
      }}
      onCancel={onClose}
      submitLabel={app ? "Guardar cambios" : "Crear"}
    >
      {({ values, setField, errors }) => (
        <>
          <Input
            label="Nombre"
            required
            value={values.name}
            onChange={(e) => setField("name", e.target.value)}
            error={errors.name}
            hint="Único en el sistema"
          />
          <div className="h-3" />
          <Input
            label="Descripción"
            value={values.description ?? ""}
            onChange={(e) => setField("description", e.target.value)}
            error={errors.description}
          />
          <div className="h-3" />
          <Input
            label="URL de lanzamiento"
            value={values.launchUrl ?? ""}
            onChange={(e) => setField("launchUrl", e.target.value)}
            error={errors.launchUrl}
            hint="A dónde lleva esta app tras el login — relativa (/admin/) para esta misma SPA, absoluta para una app externa"
          />
        </>
      )}
    </Form>
  );
}

function DisabledTabHint() {
  return (
    <p className="text-sm text-slate-500">
      Guarda la app primero para habilitar la gestión de vinculaciones.
    </p>
  );
}

/* ====================== Binding tabs ====================== */

/**
 * The four binding tabs share the same checked-list shape —
 * the renderer is now the shared {@link BindingTab} primitive
 * (see {@code components/ui/BindingTab}). Each tab here is a
 * thin adapter: pick the right checked-hook + bind/unbind
 * pair, pass {@code entityId={app.id}} and
 * {@code listTestIdPrefix="app-bindings"}, and the cell renderer.
 */
/* ====================== Binding tabs ====================== */

/**
 * Builds the shared {@link BulkAction} descriptor for a binding
 * tab. Two helper closures wrap bind/unbind so the toolbar can
 * fan out across the currently-filtered slice in one click. The
 * fan-out is best-effort: each row is its own POST/DELETE, and
 * a single failure doesn't abort the rest (React Query mutations
 * are independent and each invalidates the {@code …/checked}
 * query key on settle).
 */
/* eslint-disable @typescript-eslint/no-explicit-any */
function appBulkAction(
  entityId: number,
  bind: { mutateAsync: (vars: any) => Promise<unknown> },
  unbind: { mutateAsync: (vars: any) => Promise<unknown> },
  rowArgKey: "roleId" | "userId" | "routeId" | "microserviceId",
  testIdPrefix: string,
): BulkAction {
  return {
    bindLabel: "Vincular visibles",
    unbindLabel: "Desvincular visibles",
    testIdPrefix,
    onApply: (rowIds, action) => {
      const mutator = action === "bind" ? bind : unbind;
      void Promise.all(
        rowIds.map((rid) =>
          mutator.mutateAsync({ id: entityId, [rowArgKey]: rid }),
        ),
      );
    },
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

function RolesTab({ appId }: { appId: number }) {
  const roles = useAppRolesChecked(appId);
  const bind = useBindAppRole();
  const unbind = useUnbindAppRole();
  const pending = bind.isPending || unbind.isPending;
  return (
    <BindingTab<AppRoleChecked>
      entityId={appId}
      listTestIdPrefix="app-bindings"
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
          void unbind.mutateAsync({ id: appId, roleId });
        } else {
          void bind.mutateAsync({ id: appId, roleId });
        }
      }}
      bulkAction={appBulkAction(appId, bind, unbind, "roleId", "role-bulk")}
      renderRow={(r) => r.name}
    />
  );
}

function UsersTab({ appId }: { appId: number }) {
  const users = useAppUsersChecked(appId);
  const bind = useBindAppUser();
  const unbind = useUnbindAppUser();
  const pending = bind.isPending || unbind.isPending;
  return (
    <BindingTab<AppUserChecked>
      entityId={appId}
      listTestIdPrefix="app-bindings"
      data={users.data}
      isLoading={users.isLoading}
      isPending={pending}
      emptyText="No hay usuarios creados."
      toggleIdPrefix="user-toggle"
      searchPlaceholder="Buscar usuario…"
      // Post-V12 the per-app user binding renders the
      // fullName when set, falling back to email (since the
      // `username` slot no longer exists in
      // `AppUserChecked`). The search still matches
      // against `email` so admins can locate rows by either
      // identifier.
      getRowLabel={(u) => u.fullName ?? u.email}
      getRowId={(u) => u.userId}
      getRowChecked={(u) => u.checked}
      onToggle={(userId, checked) => {
        if (checked) {
          void unbind.mutateAsync({ id: appId, userId });
        } else {
          void bind.mutateAsync({ id: appId, userId });
        }
      }}
      bulkAction={appBulkAction(appId, bind, unbind, "userId", "user-bulk")}
      renderRow={(u) => u.fullName ?? u.email}
    />
  );
}

function RoutesTab({ appId }: { appId: number }) {
  const routes = useAppRoutesChecked(appId);
  const bind = useBindAppRoute();
  const unbind = useUnbindAppRoute();
  const pending = bind.isPending || unbind.isPending;
  return (
    <BindingTab<AppRouteChecked>
      entityId={appId}
      listTestIdPrefix="app-bindings"
      data={routes.data}
      isLoading={routes.isLoading}
      isPending={pending}
      emptyText="No hay rutas creadas."
      toggleIdPrefix="route-toggle"
      searchPlaceholder="Buscar ruta…"
      getRowLabel={(r) => `${r.name} ${r.path}`.trim()}
      getRowId={(r) => r.routeId}
      getRowChecked={(r) => r.checked}
      onToggle={(routeId, checked) => {
        if (checked) {
          void unbind.mutateAsync({ id: appId, routeId });
        } else {
          void bind.mutateAsync({ id: appId, routeId });
        }
      }}
      bulkAction={appBulkAction(appId, bind, unbind, "routeId", "route-bulk")}
      renderRow={(r) => (
        <span>
          {r.name}
          <span className="ml-2 text-xs text-slate-500">{r.path}</span>
        </span>
      )}
    />
  );
}

function MicroservicesTab({ appId }: { appId: number }) {
  const services = useAppMicroservicesChecked(appId);
  const bind = useBindAppMicroservice();
  const unbind = useUnbindAppMicroservice();
  const pending = bind.isPending || unbind.isPending;
  return (
    <BindingTab<AppMicroserviceChecked>
      entityId={appId}
      listTestIdPrefix="app-bindings"
      data={services.data}
      isLoading={services.isLoading}
      isPending={pending}
      emptyText="No hay microservicios creados."
      toggleIdPrefix="microservice-toggle"
      searchPlaceholder="Buscar microservicio…"
      getRowLabel={(m) => `${m.serviceId} ${m.kind}`}
      getRowId={(m) => m.microserviceId}
      getRowChecked={(m) => m.checked}
      onToggle={(microserviceId, checked) => {
        if (checked) {
          void unbind.mutateAsync({ id: appId, microserviceId });
        } else {
          void bind.mutateAsync({ id: appId, microserviceId });
        }
      }}
      bulkAction={appBulkAction(appId, bind, unbind, "microserviceId", "microservice-bulk")}
      renderRow={(m) => (
        <span>
          <span className="font-mono">{m.serviceId}</span>
          <span
            className={[
              "ml-2 rounded px-1.5 py-0.5 text-[10px] font-medium",
              m.kind === "QUERY"
                ? "bg-violet-50 text-violet-700"
                : "bg-slate-100 text-slate-700",
            ].join(" ")}
          >
            {m.kind}
          </span>
        </span>
      )}
    />
  );
}