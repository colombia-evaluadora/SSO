/**
 * Typed wrappers over {@link apiClient} — one per backend endpoint.
 * The functions are intentionally thin; no transformation, no
 * caching (TanStack Query handles that). The benefit over calling
 * {@code apiClient.get} directly is a single import for the page
 * code, type safety, and a place to attach Zod runtime validation
 * in a follow-up if a backend field changes shape.
 */
import { apiClient } from "./client";
import { env } from "@/env";
import type {
  AppMicroserviceChecked,
  AppRequest,
  AppResponse,
  AppRoleChecked,
  AppRouteChecked,
  AppSummary,
  AppUserChecked,
  BindUserRoleRequest,
  ContainerStatusResponse,
  CreateAccountRequest,
  EndpointMicroserviceChecked,
  EndpointRequest,
  EndpointResponse,
  EndpointRoleChecked,
  GroupRequest,
  GroupResponse,
  GroupRoleChecked,
  LoginRequest,
  MicroserviceRequest,
  MicroserviceResponse,
  MicroserviceTestConnectionRequest,
  MicroserviceTestConnectionResponse,
  QueryAdminRequest,
  QueryAdminResponse,
  QueryExecutionRequest,
  QueryExecutionResponse,
  QueryRoleChecked,
  RoleRequest,
  RoleResponse,
  RouteRequest,
  RouteResponse,
  RouteRoleChecked,
  TokenResponse,
  UpdateAccountRequest,
  UserResponse,
  UserRoleChecked,
  WriteDefinitionRequest,
  WriteDefinitionResponse,
  WriteRoleChecked,
} from "./types";

// ====================== auth ======================

export const authApi = {
  // skipAuth: a 401 here means "bad credentials", not "expired
  // session" — we don't want the client to try /auth/refresh.
  login: (body: LoginRequest) =>
    apiClient.post<TokenResponse>("/auth/login", body, { skipAuth: true }),
  logout: () => apiClient.post<void>("/auth/logout"),
  // Public (permitAll on sso-admin's SecurityConfig) — the user
  // hasn't logged in yet, they're requesting a reset link. Always
  // resolves 200 even for an unknown email (UserAdminService never
  // discloses which addresses are registered) — the caller can't
  // distinguish "email sent" from "email unknown" by design.
  forgotPassword: (email: string) =>
    apiClient.get<void>(`/sso-admin/forgotPassword?email=${encodeURIComponent(email)}`, {
      skipAuth: true,
    }),
  // Apps the caller's roles have role_app access to — powers the
  // post-login launcher (AppLauncherPage). Lives on auth-center,
  // not sso-admin: it's shared, app-agnostic infrastructure, same
  // category as login/logout.
  myApps: () => apiClient.get<AppSummary[]>("/auth/myApps"),
};

// ====================== users ======================

export const usersApi = {
  list: () => apiClient.get<UserResponse[]>("/sso-admin/getUsers"),
  // The backend's user-role-by-username endpoint was renamed
  // getRolesByEmail in the V12 refactor (email is the unique
  // login identifier). It's path-based, lives under
  // /sso-admin/getRolesByEmail?email=... and returns a string
  // list of role names bound to that user.
  getRolesByEmail: (email: string) =>
    apiClient.get<string[]>(`/sso-admin/getRolesByEmail?email=${encodeURIComponent(email)}`),
  getRolesByUserId: (userId: number) =>
    apiClient.get<RoleResponse[]>(`/sso-admin/user/roles?userId=${userId}`),
  getRolesChecked: (userId: number) =>
    apiClient.get<UserRoleChecked[]>(`/sso-admin/user/roles/checked?userId=${userId}`),
  create: (body: CreateAccountRequest) => apiClient.post<UserResponse>("/sso-admin/createAccount", body),
  update: (body: UpdateAccountRequest) => apiClient.put<UserResponse>("/sso-admin/updateAccount", body),
  // Only valid while the user is PENDING_ACTIVATION / ACTIVE /
  // INACTIVE respectively — the backend returns 409 otherwise.
  resendActivation: (userId: number) =>
    apiClient.post<void>(`/sso-admin/resendActivation/${userId}`),
  deactivate: (userId: number, reason?: string) =>
    apiClient.post<void>(
      `/sso-admin/deactivateAccount/${userId}${reason ? `?reason=${encodeURIComponent(reason)}` : ""}`,
    ),
  reactivate: (userId: number) =>
    apiClient.post<void>(`/sso-admin/reactivateAccount/${userId}`),
  bindRole: (body: BindUserRoleRequest) => apiClient.post<void>("/sso-admin/bindUserRole", body),
  unbindRole: (userId: number, roleId: number) =>
    apiClient.delete<void>(
      `/sso-admin/unbindUserRole?userId=${userId}&roleId=${roleId}`,
    ),
};

// ====================== roles ======================

export const rolesApi = {
  list: () => apiClient.get<RoleResponse[]>("/sso-admin/role/getRoles"),
  create: (body: RoleRequest) => apiClient.post<RoleResponse>("/sso-admin/role/createRole", body),
  update: (body: RoleRequest) => apiClient.put<RoleResponse>("/sso-admin/role/updateRole", body),
  getUsersChecked: (roleId: number) =>
    apiClient.get<UserRoleChecked[]>(`/sso-admin/role/users/checked?roleId=${roleId}`),
};

// ====================== groups ======================

export const groupsApi = {
  list: () => apiClient.get<GroupResponse[]>("/sso-admin/group"),
  save: (body: GroupRequest) => apiClient.post<GroupResponse>("/sso-admin/group", body),
  update: (body: GroupRequest) => apiClient.put<GroupResponse>("/sso-admin/group/update", body),
  bindUser: (userId: number, groupId: number) =>
    apiClient.post<void>("/sso-admin/group/bindUserGroup", { userId, groupId }),

  /* ============== role family ============== */
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/group/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/group/${id}/role/${roleId}`),
  getRolesChecked: (id: number) =>
    apiClient.get<GroupRoleChecked[]>(`/sso-admin/group/${id}/roles/checked`),
};

// ====================== microservice ======================

export const microservicesApi = {
  list: () => apiClient.get<MicroserviceResponse[]>("/sso-admin/microservice/getMicroservices"),
  create: (body: MicroserviceRequest) =>
    apiClient.post<MicroserviceResponse>("/sso-admin/microservice/save", body),
  update: (body: MicroserviceRequest) =>
    apiClient.put<MicroserviceResponse>("/sso-admin/microservice/update", body),
  delete: (id: number) => apiClient.delete<void>(`/sso-admin/microservice/${id}`),
  /**
   * Probe-only: opens a JDBC connection with the given fields and
   * reports success/failure. No persistence. Used by the "Probar
   * conexión" button in the drawer to validate the JDBC block
   * before submitting the create/update.
   */
  testConnection: (body: MicroserviceTestConnectionRequest) =>
    apiClient.post<MicroserviceTestConnectionResponse>(
      "/sso-admin/microservice/testConnection",
      body,
    ),
};

/* ====================== query-service container (provisioner-backed) ======================
 *
 * The provisioner is internal-only (compose port 9000 has no
 * host mapping). sso-admin proxies these calls so the browser
 * only ever talks to the gateway. The endpoints here describe
 * the contract the backend is expected to implement; the admin-ui
 * ships them now so the page is ready when the proxy endpoints
 * land.
 *
 * POST /restart returns 202 Accepted — the restart is async
 * (provisioner issues stop+start, takes 1-3s). The UI fires it
 * and the next status poll picks up the new state.
 */
export const queryServicesApi = {
  status: (id: number) =>
    apiClient.get<ContainerStatusResponse>(`/sso-admin/microservice/${id}/container/status`),
  logs: (id: number, tail = 200) =>
    apiClient.get<string>(`/sso-admin/microservice/${id}/container/logs?tail=${tail}`),
  restart: (id: number) =>
    apiClient.post<void>(`/sso-admin/microservice/${id}/container/restart`),
};

// ====================== endpoint ======================

export const endpointsApi = {
  list: () => apiClient.get<EndpointResponse[]>("/sso-admin/endpoint/getEndpoints"),
  create: (body: EndpointRequest) =>
    apiClient.post<EndpointResponse>("/sso-admin/endpoint/save", body),
  update: (body: EndpointRequest) =>
    apiClient.put<EndpointResponse>("/sso-admin/endpoint/update", body),
  delete: (id: number) => apiClient.delete<void>(`/sso-admin/endpoint/${id}`),
  bindMicroservice: (id: number, microserviceId: number) =>
    apiClient.post<void>(`/sso-admin/endpoint/${id}/microservice/${microserviceId}`),
  unbindMicroservice: (id: number, microserviceId: number) =>
    apiClient.delete<void>(`/sso-admin/endpoint/${id}/microservice/${microserviceId}`),
  getMicroservicesChecked: (id: number) =>
    apiClient.get<EndpointMicroserviceChecked[]>(`/sso-admin/endpoint/${id}/microservices/checked`),
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/endpoint/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/endpoint/${id}/role/${roleId}`),
  getRolesChecked: (id: number) =>
    apiClient.get<EndpointRoleChecked[]>(`/sso-admin/endpoint/${id}/roles/checked`),
};

// ====================== route ======================

export const routesApi = {
  list: () => apiClient.get<RouteResponse[]>("/sso-admin/route/getRoutes"),
  listByParent: (idParent: number | null) => {
    const q = idParent == null ? "" : `?idParent=${idParent}`;
    return apiClient.get<RouteResponse[]>(`/sso-admin/route/getRoutesByParent${q}`);
  },
  create: (body: RouteRequest) => apiClient.post<RouteResponse>("/sso-admin/route/save", body),
  update: (body: RouteRequest) => apiClient.put<RouteResponse>("/sso-admin/route/update", body),
  delete: (id: number) => apiClient.delete<void>(`/sso-admin/route/${id}`),
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/route/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/route/${id}/role/${roleId}`),
  getRolesChecked: (id: number) =>
    apiClient.get<RouteRoleChecked[]>(`/sso-admin/route/${id}/roles/checked`),
};

/* ====================== query execution ======================
 *
 *  - `execute` — POST directly to the query-service instance
 *    backing the chosen microservice. The path is
 *    /<serviceId>/query (NO /api prefix) because the gateway's
 *    dynamic discovery locator exposes /<svcId>/** without it.
 *    The apiClient `base: ""` override skips VITE_API_BASE; the
 *    JWT travels in Authorization, the gateway forwards it.
 */
/* ====================== queries admin CRUD ======================
 *
 * Distinct from the consumer-side myQueries/execute pair above.
 * The admin surface is /query/getQueries (ADMIN-gated) and is what
 * the Queries Catalog admin page uses for list/create/update/delete
 * plus the role-binding endpoints. Bound to a kind=QUERY microservice
 * by sending microserviceId in the body.
 */
export const queryAdminApi = {
  list: () => apiClient.get<QueryAdminResponse[]>("/sso-admin/query/getQueries"),
  create: (body: QueryAdminRequest) =>
    apiClient.post<QueryAdminResponse>("/sso-admin/query/save", body),
  update: (body: QueryAdminRequest) =>
    apiClient.put<QueryAdminResponse>("/sso-admin/query/update", body),
  delete: (id: number) => apiClient.delete<void>(`/sso-admin/query/${id}`),
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/query/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/query/${id}/role/${roleId}`),
  getRolesChecked: (id: number) =>
    apiClient.get<QueryRoleChecked[]>(`/sso-admin/query/${id}/roles/checked`),
};

export const queriesApi = {
  execute: (instanceName: string | null, body: QueryExecutionRequest) => {
    // instanceName === null is the legacy single-instance case
    // (the canonical "query-service" service id registered with
    // Eureka, NOT "query-service-postgres" — see
    // query-service's InstanceNameResolver).
    const serviceId = instanceName ? `query-service-${instanceName}` : "query-service";
    return apiClient.post<QueryExecutionResponse>(
      `/${serviceId}/query`,
      body,
      { base: "" },
    );
  },
};

// ====================== menu ======================

/**
 * The per-caller visible sidebar menu. Backed by
 * {@code GET /sso-admin/myMenu}, which is
 * {@code .authenticated()} on the server (NOT
 * {@code hasRole("ADMIN")}) — non-admin users with route
 * bindings also get a 200 + a (possibly empty) filtered list.
 *
 * <p>Filtering happens server-side via
 * {@code RouteRepository.findVisibleForRoles(roleIds)}: the
 * union of (a) routes whose {@code id_app} is bound to one
 * of the caller's roles AND (b) routes with a direct
 * {@code ROLE_ROUTE} binding for one of the caller's
 * roles. The SPA receives the already-filtered list and
 * simply renders it — no client-side trust required.
 *
 * <p>An empty array is a legitimate "no menu access"
 * outcome, NOT an error.
 */
export const menuApi = {
  /**
   * The caller-keyed sidebar entries. Cached by TanStack
   * Query under {@code ["myMenu"]} — see
   * {@link useMyMenu}.
   *
   * <p>When {@code VITE_APP_NAME} is set in the build (it
   * usually is for deployed SPA bundles), this method
   * appends {@code ?app=<name>} so the backend resolves
   * the name to an {@code App.id} and runs the scoped
   * {@code RouteRepository.findVisibleForRoles(roleIds,
   * appId)} — the SPA then sees ONLY the routes of its
   * own app, never the menus of other apps the same user
   * might be entitled to.
   *
   * <p>Without {@code VITE_APP_NAME}, the call goes out
   * un-scoped and returns the union across every app
   * the caller's roles grant — the pre-scoping behavior,
   * useful for CI + dev sandboxes.
   */
  getMyMenu: () => {
    const qs = env.VITE_APP_NAME
      ? `?app=${encodeURIComponent(env.VITE_APP_NAME)}`
      : "";
    return apiClient.get<RouteResponse[]>(`/sso-admin/myMenu${qs}`);
  },
};

// ====================== apps ======================

/**
 * CRUD + 4-family bindings for the App entity (SSO_V2).
 *
 * <p>The binding endpoints follow the same convention as
 * {@link routesApi}: POST binds, DELETE unbinds, GET
 * {@code /<family>s/checked} returns all rows in the target
 * table each with a {@code checked: boolean} so the UI can
 * render a per-row toggle list (the legacy {@code QueriesAdminPage}
 * pattern). Bind calls return 204; the wire returns no body
 * beyond HTTP status.
 */
export const appsApi = {
  /* ============== CRUD ============== */
  list: () => apiClient.get<AppResponse[]>("/sso-admin/app/getApps"),
  getById: (id: number) =>
    apiClient.get<AppResponse>(`/sso-admin/app/${id}`),
  create: (body: AppRequest) =>
    apiClient.post<AppResponse>("/sso-admin/app/save", body),
  update: (body: AppRequest) =>
    apiClient.put<AppResponse>("/sso-admin/app/update", body),
  delete: (id: number) =>
    apiClient.delete<void>(`/sso-admin/app/${id}`),

  /* ============== role family ============== */
  getRolesChecked: (id: number) =>
    apiClient.get<AppRoleChecked[]>(`/sso-admin/app/${id}/roles/checked`),
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/app/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/app/${id}/role/${roleId}`),

  /* ============== user family ============== */
  getUsersChecked: (id: number) =>
    apiClient.get<AppUserChecked[]>(`/sso-admin/app/${id}/users/checked`),
  bindUser: (id: number, userId: number) =>
    apiClient.post<void>(`/sso-admin/app/${id}/user/${userId}`),
  unbindUser: (id: number, userId: number) =>
    apiClient.delete<void>(`/sso-admin/app/${id}/user/${userId}`),

  /* ============== route family ============== */
  getRoutesChecked: (id: number) =>
    apiClient.get<AppRouteChecked[]>(`/sso-admin/app/${id}/routes/checked`),
  bindRoute: (id: number, routeId: number) =>
    apiClient.post<void>(`/sso-admin/app/${id}/route/${routeId}`),
  unbindRoute: (id: number, routeId: number) =>
    apiClient.delete<void>(`/sso-admin/app/${id}/route/${routeId}`),

  /* ============== microservice family ============== */
  getMicroservicesChecked: (id: number) =>
    apiClient.get<AppMicroserviceChecked[]>(
      `/sso-admin/app/${id}/microservices/checked`,
    ),
  bindMicroservice: (id: number, microserviceId: number) =>
    apiClient.post<void>(
      `/sso-admin/app/${id}/microservice/${microserviceId}`,
    ),
  unbindMicroservice: (id: number, microserviceId: number) =>
    apiClient.delete<void>(
      `/sso-admin/app/${id}/microservice/${microserviceId}`,
    ),
};

/**
 * Admin CRUD + role-binding for the WriteDefinition entity.
 *
 * <p>{@code columns} / {@code keyColumns} travel as
 * JSON-as-string (see {@code WriteDefinitionRequest}). The
 * form wraps both in the {@code <ChipInput>} primitive so the
 * wire shape is the only place the JSON-as-string detail
 * surfaces.
 *
 * <p>Same shape as {@link appsApi}: 5 CRUD + 3 role-binding.
 * 1 binding family because writes only bind to roles (no
 * users/routes/microservices in v1).
 */
export const writesApi = {
  /* ============== CRUD ============== */
  list: () => apiClient.get<WriteDefinitionResponse[]>("/sso-admin/write/getWrites"),
  getById: (id: number) =>
    apiClient.get<WriteDefinitionResponse>(`/sso-admin/write/${id}`),
  /** Legacy read-side lookup by UUID. Kept for callers that
   *  have only the handle (e.g. cross-service integration). */
  getByUuid: (uuid: string) =>
    apiClient.get<WriteDefinitionResponse>(
      `/sso-admin/write/byUuid?uuid=${encodeURIComponent(uuid)}`,
    ),
  create: (body: WriteDefinitionRequest) =>
    apiClient.post<WriteDefinitionResponse>("/sso-admin/write/save", body),
  update: (body: WriteDefinitionRequest) =>
    apiClient.put<WriteDefinitionResponse>("/sso-admin/write/update", body),
  delete: (id: number) =>
    apiClient.delete<void>(`/sso-admin/write/${id}`),

  /* ============== role family ============== */
  getRolesChecked: (id: number) =>
    apiClient.get<WriteRoleChecked[]>(`/sso-admin/write/${id}/roles/checked`),
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/write/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/write/${id}/role/${roleId}`),
};
