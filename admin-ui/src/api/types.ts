/**
 * Mirrored DTOs from the backend. Kept in sync by hand — for ~30
 * types the cost of a Java→TS codegen is not worth the toolchain
 * complexity. The runtime validators in src/api/schemas.ts are the
 * real source of truth for shapes the API actually returns.
 */

// ====================== auth-center ======================

export interface LoginRequest {
  // Wire key changed from `username` to `email` in the V12
  // refactor (email is the unique login identifier; the
  // legacy `users.username` column is gone).
  email: string;
  password: string;
}

export interface TokenResponse {
  token: string;
  refreshToken: string;
  expiresIn: number; // seconds
}

export interface UserSummary {
  id: number;
  email: string;
  fullName: string;
  enabled: boolean;
  ldap: boolean;
  roles: string[];
}

// ====================== sso-admin / users ======================

export type UserStatus = "PENDING_ACTIVATION" | "ACTIVE" | "INACTIVE";

export interface UserResponse {
  id: number;
  fullName: string;
  email: string;
  active: boolean;
  enabled: boolean;
  ldap: boolean;
  status: UserStatus;
  roleNames: string[];
}

/**
 * Wire shape for {@code POST /sso-admin/createAccount}. The
 * admin no longer sends a password — the user sets one by
 * clicking the activation link in the email. The
 * {@code /activateAccount} endpoint is the only place a
 * password first enters the system for the new account.
 *
 * <p>Post-V12, the wire shape does NOT include `username` —
 * email IS the login identifier and the only login-shaped
 * field on the row.
 */
export interface CreateAccountRequest {
  fullName: string;
  email: string;
  roleNames: string[];
}

/**
 * Wire shape for {@code PUT /sso-admin/updateAccount}. The
 * lookup key is the numeric {@code id} (the user's PK) —
 * email is mutable, so it isn't a stable identifier; the id
 * is. See {@code com.co.eurekatic.ssoadmin.dto.UpdateAccountRequest}.
 *
 * <p>Password changes are NOT handled here — see
 * {@code forgotPassword} + {@code restorePassword} for the
 * user-driven flow. An admin who needs to reset a forgotten
 * password triggers {@code GET /forgotPassword?email=…} on
 * behalf of the user.
 */
export interface UpdateAccountRequest {
  id: number;
  fullName?: string;
  email?: string;
  roleNames?: string[];
}

export interface BindUserRoleRequest {
  userId: number;
  roleId: number;
}

/**
 * Per-role checked-listing of users (used in the role-edit
 * drawer). The identifying slot became {@code email} in the
 * V12 refactor; full name is a separate column for display.
 */
export interface UserRoleChecked {
  userId: number;
  email: string;
  fullName: string;
  checked: boolean;
}

// ====================== sso-admin / roles ======================

export interface RoleResponse {
  id: number;
  name: string;
  description: string;
}

export interface RoleRequest {
  id?: number;
  name: string;
  description: string;
}

// ====================== sso-admin / groups ======================

export interface GroupResponse {
  id: number;
  name: string;
  description: string;
  memberCount: number;
}

export interface GroupRequest {
  id?: number;
  name: string;
  description: string;
}

/** Per-group checked-listing of roles. Mirrors
 *  {@code com.co.eurekatic.ssoadmin.service.GroupService.RoleChecked}. */
export interface GroupRoleChecked {
  roleId: number;
  name: string;
  checked: boolean;
}

// ====================== sso-admin / microservice ======================

export type MicroserviceKind = "REST" | "QUERY";

export interface MicroserviceResponse {
  id: number;
  serviceId: string;
  description: string;
  requestUri: string;
  targetUriPath: string;
  targetUrlHost: string;
  targetUrlPort: string;
  createdDate: string;

  /* ====================== provisioning (QUERY kind) ====================== */
  /** Always present (the DB column is NOT NULL DEFAULT 'REST'). */
  kind: MicroserviceKind;
  /** Null for REST rows. */
  dialect: string | null;
  jdbcUrl: string | null;
  dbUsername: string | null;
  /** Backend deliberately omits this from the wire shape
   *  ({@code MicroserviceResponse.fromEntity} returns null
   *  for {@code dbPassword}); the form re-sends it on
   *  updates. */
  dbPassword: string | null;
  poolSize: number | null;
  instanceName: string | null;
}

export interface MicroserviceRequest {
  id?: number;
  serviceId: string;
  description: string;
  requestUri: string;
  targetUriPath: string;
  targetUrlHost: string;
  targetUrlPort: string;

  /* ====================== provisioning (QUERY kind) ====================== */
  /** Defaults to {@code "REST"} on the wire if omitted. */
  kind?: MicroserviceKind;
  dialect?: string | null;
  jdbcUrl?: string | null;
  dbUsername?: string | null;
  dbPassword?: string | null;
  poolSize?: number | null;
  instanceName?: string | null;
}

/* ====================== testConnection probe ======================
 *
 * Payload/response for POST /sso-admin/microservice/testConnection.
 * Used by the "Probar conexión" button in the microservice form
 * drawer to validate the JDBC fields BEFORE saving. Dialect-agnostic
 * — the backend opens the connection via DriverManager and runs
 * Connection.isValid(5) with the configured driver. No DDL, no
 * arbitrary SQL — this is a probe, not a SQL executor.
 */
export interface MicroserviceTestConnectionRequest {
  jdbcUrl: string;
  dbUsername: string;
  dbPassword: string;
  dialect?: string;
}

export interface MicroserviceTestConnectionResponse {
  ok: boolean;
  /** Sanitized, single-line message safe to display inline. */
  message: string;
  /** Probe latency in milliseconds; only meaningful when ok=true. */
  latencyMs: number;
  /** Echo of the dialect from the request; null on failure. */
  dialect: string | null;
}

/* ====================== sso-admin / container status ======================
 *
 * Returned by GET /sso-admin/microservice/{id}/container/status.
 * The backend proxies to the provisioner's
 * GET /provision/{fullName}/status, translates the Docker
 * state string into a normalized value, and adds the
 * timestamp. `state` is null when the container does not
 * exist on the host (provisioner returns 404 → backend
 * returns 200 with state=null so the UI can render an
 * "absent" badge without throwing).
 */
export interface ContainerStatusResponse {
  /** Normalized container state — see StatusBadge for the
   *  full list. Raw Docker state is in {@link rawState}. */
  state:
    | "running"
    | "exited"
    | "created"
    | "paused"
    | "restarting"
    | "dead"
    | "removing"
    | "absent"
    | "provisioning"
    | "unknown";
  /** Original Docker Engine API state string. Useful for
   *  debugging — surfaced in a tooltip on the status badge. */
  rawState: string | null;
  /** Container id from Docker, null when absent. */
  containerId: string | null;
  /** ISO-8601 timestamp of the last container start (per
   *  the Docker inspect response). Null when absent. */
  startedAt: string | null;
  /** Full container name (`query-service-<instanceName>`). */
  fullName: string;
}

// ====================== sso-admin / endpoint ======================

export interface EndpointResponse {
  id: number;
  method: string;
  path: string;
  description: string;
  numberParams: number;
  microserviceIds: number[];
}

export interface EndpointRequest {
  id?: number;
  method: string;
  path: string;
  description: string;
  numberParams: number;
}

export interface EndpointRoleChecked {
  roleId: number;
  name: string;
  checked: boolean;
}

export interface EndpointMicroserviceChecked {
  microserviceId: number;
  serviceId: string;
  checked: boolean;
}

// ====================== sso-admin / route ======================

/**
 * Wire shape for a `Route` row. Mirrors the backend
 * {@code com.co.eurekatic.ssoadmin.dto.RouteResponse} record.
 * No `appId`/`appName` field — a route's app membership is the
 * `app_route` M:N (a route can belong to more than one app),
 * managed via the App edit page's route picker
 * (`appsApi.bindRoute`/`unbindRoute`), not a single FK on Route.
 *
 * <p>{@code idParent} is {@code null} for roots. Legacy data
 * may carry {@code 0} as the root sentinel; the
 * {@link buildTree} util normalises both.
 *
 * <p>{@code roleIds} is the set of role ids this Route is
 * directly bound to (the {@code ROLE_ROUTE} join table).
 * Per-row authorization for {@code GET /sso-admin/myMenu}
 * uses BOTH this direct binding AND the route's app_route
 * membership → app's {@code role_app} chain — see
 * {@code RouteRepository.findVisibleForRoles}.
 */
export interface RouteResponse {
  id: number;
  name: string;
  icon: string;
  path: string;
  menuOrder: number;
  type: string;
  idParent: number | null;
  roleIds: number[];
}

export interface RouteRequest {
  id?: number;
  name: string;
  icon: string;
  path: string;
  menuOrder: number;
  type: string;
  idParent: number | null;
}

export interface RouteRoleChecked {
  roleId: number;
  name: string;
  checked: boolean;
}

// ====================== sso-admin / query catalog ======================

/**
 * Read-side wire shape for {@code GET /sso-admin/myQueries} and
 * {@code GET /sso-admin/getQuery?uuid=...}. Mirrors the backend
 * {@code QueryDefinition} record. The JSON keys line up with the
 * legacy uppercase column names so the legacy low-code client
 * keeps parsing the same shape.
 *
 * `microserviceId` is NEW — it tells the UI which
 * `query-service-<instanceName>` gateway path to call when
 * executing the query. `null` means "global" (no specific
 * instance binding); the UI falls back to the legacy canonical
 * `query-service` service id in that case.
 */
export interface QueryDefinition {
  idQuery: number;
  uuid: string;
  query: string;
  type: string | null;
  publicEnd: boolean;
  captcha: boolean;
  detail: string | null;
  action: string | null;
  style: string | null;
  microserviceId: number | null;
}

/** Admin CRUD request for the catalog. Mirrors
 *  {@code QueryRequest} on the backend, including
 *  {@code microserviceId} which binds the query to a
 *  {@code query-service-<instance>} container. Sending
 *  {@code null} / omitting the field clears the binding (the
 *  query becomes "global" — any QUERY instance with the right
 *  datasource may serve it). The service rejects non-null ids
 *  that don't resolve to a {@code kind=QUERY} row with 422. */
export interface QueryAdminRequest {
  id?: number;
  uuid: string;
  query: string;
  type?: string | null;
  publicEnd: boolean;
  captcha: boolean;
  detail?: string | null;
  action?: string | null;
  style?: string | null;
  microserviceId?: number | null;
}

/** Admin CRUD response shape — mirrors {@code QueryResponse}
 *  on the backend. Distinct from {@link QueryDefinition}
 *  (the catalog/consumer shape) so the admin UI doesn't load
 *  the role-bindings endpoint separately; the id, roleIds, and
 *  microserviceId live here. */
export interface QueryAdminResponse {
  id: number;
  uuid: string;
  query: string;
  type: string | null;
  publicEnd: boolean;
  captcha: boolean;
  detail: string | null;
  action: string | null;
  style: string | null;
  createdDate: string | null;
  roleIds: number[];
  microserviceId: number | null;
}

/** Per-row role binding checkbox list — mirrors
 *  {@code QueryAdminService.RoleChecked}. */
export interface QueryRoleChecked {
  roleId: number;
  name: string;
  checked: boolean;
}

/** Value type for a query parameter. query-service forwards
 *  these as `MapSqlParameterSource` bindings — strings, numbers,
 *  booleans, and null are all supported; the JDBC driver handles
 *  the SQL type mapping. */
export type QueryParamValue = string | number | boolean | null;

// ====================== sso-admin / apps ======================

/**
 * CRUD payload for the App entity. {@code id} is only required
 * for {@code update}; the create endpoint ignores it. Bindings
 * (roles/users/routes/microservices) are NOT sent here — they're
 * managed via the dedicated POST/DELETE endpoints so each
 * association is a single round-trip the UI can audit one click
 * at a time.
 */
export interface AppRequest {
  id?: number;
  name: string;
  description?: string | null;
  launchUrl?: string | null;
}

/**
 * Read shape for {@code GET /sso-admin/app/getApps} and the
 * per-id variant. {@code roleIds / userIds / routeIds /
 * microserviceIds} are denormalized on the row so the table
 * can render binding counts without a fan-out round-trip.
 * {@code createdDate} is ISO-8601 from the DB default.
 */
export interface AppResponse {
  id: number;
  name: string;
  description: string | null;
  launchUrl: string | null;
  createdDate: string;
  roleIds: number[];
  userIds: number[];
  routeIds: number[];
  microserviceIds: number[];
}

/**
 * One entry of {@code GET /auth/myApps} — the apps the caller's
 * roles have a {@code role_app} binding to. Powers the post-login
 * app launcher; see {@code AppLauncherPage}.
 */
export interface AppSummary {
  id: number;
  name: string;
  description: string | null;
  launchUrl: string | null;
}

/** Per-app checked-listing of roles. Mirrors
 *  {@code com.co.eurekatic.ssoadmin.service.AppService.RoleChecked}. */
export interface AppRoleChecked {
  roleId: number;
  name: string;
  checked: boolean;
}

/** Per-app checked-listing of users. The identifying slot
 *  became {@code email} + {@code fullName} (both) in the V12
 *  refactor; full name falls back to email when null. The
 *  label only shows the full name to keep the grid readable. */
export interface AppUserChecked {
  userId: number;
  fullName: string | null;
  email: string;
  checked: boolean;
}

/** Per-app checked-listing of routes. We show both {@code name}
 *  and {@code path} in the UI so an admin can spot the wrong
 *  route by its URL even when two routes share a label. */
export interface AppRouteChecked {
  routeId: number;
  name: string;
  path: string;
  checked: boolean;
}

/** Per-app checked-listing of microservices. Identifying field
 *  is {@code serviceId} (the registry id, not the numeric pk);
 *  {@code kind} lets us badge REST vs QUERY rows in the list. */
export interface AppMicroserviceChecked {
  microserviceId: number;
  serviceId: string;
  kind: string;
  checked: boolean;
}

// ====================== sso-admin / writes ======================

/** INSERT vs UPDATE — the two flavours of write catalog row. */
export type WriteType = "INSERT" | "UPDATE";

/**
 * CRUD payload for {@code /sso-admin/write/save|update}.
 * Mirrors {@code WriteDefinitionRequest} on the backend.
 *
 * <p>{@code columns} and {@code keyColumns} are sent across the
 * wire as JSON-as-string (the backend stores them in a
 * single-column TEXT field). The admin form shapes them as
 * {@code string[]} via the chip input and serializes with
 * {@code JSON.stringify} on submit
 * — see {@code WriteFormDrawer}.
 *
 * <p>{@code keyColumns} is optional (the entity column is
 * nullable); the form sends {@code null} when the chip list
 * is empty. {@code columns} is required.
 *
 * <p>{@code microserviceId} binds the write to a
 * {@code query-service-<instance>} container (must be
 * {@code kind=QUERY}; the form's dropdown already filters).
 * Sending {@code null} / omitting the field keeps the write
 * "global" so any QUERY instance with the right datasource
 * may serve it. Backed by the
 * {@code WRITE_DEFINITION.MICROSERVICE_ID} FK added in
 * migration {@code postgres/init/07-add-write-microservice-fk.sh}
 * — service layer rejects non-null ids that don't resolve to
 * kind=QUERY with 400 INVALID_REQUEST.
 */
export interface WriteDefinitionRequest {
  id?: number;
  uuid: string;
  writeType: WriteType;
  tableName: string;
  columns: string;
  keyColumns: string | null;
  microserviceId?: number | null;
}

/**
 * Read shape for {@code GET /sso-admin/write/getWrites} and
 * the per-id variant. Mirrors {@code WriteDefinitionResponse}
 * on the backend. {@code columns} / {@code keyColumns} are
 * JSON-as-string (parse with {@code JSON.parse} to get the
 * {@code string[]} the chip input edits).
 *
 * <p>{@code microserviceId} is the FK surfaced for the list
 * page so each row can show its backing instance without a
 * follow-up round-trip. {@code null} = global.
 */
export interface WriteDefinitionResponse {
  id: number;
  uuid: string;
  writeType: WriteType;
  tableName: string;
  columns: string;
  keyColumns: string | null;
  createdDate: string;
  roleIds: number[];
  microserviceId: number | null;
}

/** Per-write checked-listing of roles. Mirrors
 *  {@code WriteDefinitionAdminService.RoleChecked}. The
 *  suffixed {@code roleId} + {@code checked} fields follow
 *  the module convention (App/Query/Routes/Endpoints). */
export interface WriteRoleChecked {
  roleId: number;
  name: string;
  checked: boolean;
}

// ====================== query-service / tables ======================

/**
 * Wire shape for {@code GET /query-service-<instance>/tables?dialect=…&schema=…}.
 * Mirrors the backend {@code com.co.eurekatic.query.web.metadata.TableInfo}
 * record. Returned rows are the base tables
 * ({@code types={"TABLE"}}) of the requested datasource.
 *
 * <p>Used by the admin-ui Writes Catalog "pick a table"
 * dropdown (see {@code WriteFormDrawer}). Callers join
 * {@code schema + "." + name} to build the qualified
 * {@code tableName} that goes into the
 * {@code WRITE_DEFINITION.TABLE_NAME} column.
 *
 * <p>{@code remarks} is the {@code TABLE_REMARKS} JDBC column;
 * surfaced by the controller for hover-tooltips even though
 * the form ignores it. Will be null on most dialects.
 */
export interface TableInfo {
  dialect: string;
  schema: string | null;
  name: string;
  remarks: string | null;
}

// ====================== query-service / columns ======================

/**
 * Wire shape for {@code GET /query-service-<instance>/columns?dialect=…&schema=…&table=…}.
 * Mirrors the backend {@code com.co.eurekatic.query.web.metadata.ColumnInfo}
 * record. Returned rows are the base columns of one base table
 * (the controller hardcodes {@code getColumns(…)} on the
 * JDBC side — no SQL is executed, no arbitrary types accepted
 * from the client) with the primaryKey flag joined in via a
 * sibling {@code getPrimaryKeys} call.
 *
 * <p>Used by the admin-ui Writes Catalog "pick column(s)"
 * multi-select for the {@code columns} / {@code keyColumns}
 * chip inputs. The two per-row booleans drive the UI:
 * {@code nullable} is rendered as a small chip
 * ({@code "NULL"} / {@code "NOT NULL"}) next to the data type,
 * and {@code primaryKey} tags the row with a {@code "(PK)"}
 * badge plus pre-checks the keyColumns picker on
 * {@code writeType=UPDATE}.
 *
 * <p>{@code schema} and {@code table} are echoed per row so the
 * frontend can disambiguate when two tables from different
 * schemas share a column name (e.g. {@code audit.created_at}
 * vs {@code public.created_at}).
 */
export interface ColumnInfo {
  dialect: string;
  schema: string | null;
  table: string;
  name: string;
  dataType: string;
  nullable: boolean;
  primaryKey: boolean;
}

/**
 * Body of {@code POST /query-service-<instance>/query}. The
 * service returns a list of objects keyed by JDBC column label
 * — the order is preserved by Jackson's `LinkedHashMap` on the
 * server side and rendered as a generic table client-side.
 */
export interface QueryExecutionRequest {
  uuid: string;
  params: Record<string, QueryParamValue>;
  limit?: number;
  offset?: number;
}

/** Rows returned by query-service. Each row is an object whose
 *  keys are the JDBC column labels and whose values are whatever
 *  `rs.getObject(i)` produced (numbers, strings, dates, possibly
 *  null). The UI renders them with `String(...)` and a null
 *  placeholder. */
export type QueryExecutionResponse = Array<Record<string, unknown>>;

// ====================== error envelope ======================

export interface ErrorResponse {
  code: string;
  message: string;
  timestamp: string;
}
