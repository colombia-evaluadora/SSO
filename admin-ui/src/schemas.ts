import { z } from "zod";

/**
 * Form schemas. Zod is the single source of truth — we derive
 * TS types from it and use the same schema to validate the form
 * before submit. Backend has its own validation; the point of
 * these schemas is to fail fast in the UI, not to enforce the
 * server-side contract.
 */

/**
 * Schema for the create/edit user form. The {@code username}
 * field is gone since the V12 migration — email IS the unique
 * login identifier, so it now carries both the role (login)
 * and the contact-information obligation. The wire shape sent
 * to {@code POST /sso-admin/createAccount} is exactly
 * {@code {fullName, email, roleNames}}; see
 * {@code CreateAccountRequest} in {@code src/api/types.ts}.
 */
export const userFormSchema = z.object({
  fullName: z.string().min(1, "Requerido").max(120),
  email: z.string().email("Email inválido").max(120),
  // No password field. The user picks their password at the
  // activation landing page (POST /activateAccount); the admin
  // never sees it. See CreateAccountRequest in src/api/types.ts.
  roleNames: z.array(z.string()).default([]),
});

export const roleFormSchema = z.object({
  name: z.string().min(2, "Mínimo 2 caracteres").max(60),
  description: z.string().max(200).default(""),
});

export const groupFormSchema = z.object({
  name: z.string().min(2, "Mínimo 2 caracteres").max(60),
  description: z.string().max(200).default(""),
});

/**
 * Discriminator for the two microservice flavours.
 * {@code REST} is the legacy routing-only row;
 * {@code QUERY} is a request to spin up a fresh
 * query-service container via the provisioner sidecar.
 */
export type MicroserviceKind = "REST" | "QUERY";

/**
 * When kind=QUERY these fields must be present. The cross-
 * field validation lives in the {@code .superRefine} below
 * because Zod's per-field rules can't model an "if/then"
 * cleanly. The backend also enforces this in
 * {@code MicroserviceService.create}.
 */
export const QUERY_DIALECTS = ["postgres", "oracle", "sqlserver"] as const;
export type QueryDialect = (typeof QUERY_DIALECTS)[number];

export const microserviceFormSchema = z
  .object({
    serviceId: z.string().min(2, "Mínimo 2 caracteres").max(60),
    description: z.string().max(200).default(""),
    requestUri: z.string().min(1, "Requerido").max(200),
    /* The host/port/path triumvirate is required for kind=REST
       and ignored for kind=QUERY. The cross-field "REST
       needs all three" check is enforced by the drawer's
       payload stripping and the backend's own validator —
       the schema stays permissive so a QUERY row with empty
       host/port/path validates cleanly. */
    targetUriPath: z.string().max(200).default(""),
    targetUrlHost: z.string().max(120).default(""),
    targetUrlPort: z.string().max(6).default(""),

    /* ====================== provisioning (QUERY kind) ====================== */
    kind: z.enum(["REST", "QUERY"]).default("REST"),
    dialect: z.string().default(""),
    jdbcUrl: z.string().default(""),
    dbUsername: z.string().default(""),
    dbPassword: z.string().default(""),
    poolSize: z.coerce.number().int().min(1).max(1000).default(10),
    instanceName: z.string().default(""),
  })
  .superRefine((v, ctx) => {
    if (v.kind !== "QUERY") return;
    if (!v.dialect) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["dialect"], message: "Requerido" });
    } else if (!QUERY_DIALECTS.includes(v.dialect as QueryDialect)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["dialect"],
        message: `Debe ser uno de: ${QUERY_DIALECTS.join(", ")}`,
      });
    }
    if (!v.jdbcUrl) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["jdbcUrl"], message: "Requerido" });
    }
    if (!v.dbUsername) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["dbUsername"], message: "Requerido" });
    }
    if (!v.instanceName) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["instanceName"], message: "Requerido" });
    }
  });

export const endpointFormSchema = z.object({
  method: z.enum(["GET", "POST", "PUT", "DELETE", "PATCH"], {
    errorMap: () => ({ message: "Método inválido" }),
  }),
  path: z.string().min(1, "Requerido").max(200),
  description: z.string().max(200).default(""),
  numberParams: z.coerce.number().int().min(0).max(20),
});

export const routeFormSchema = z.object({
  name: z.string().min(2, "Mínimo 2 caracteres").max(60),
  icon: z.string().max(60).default(""),
  path: z.string().min(1, "Requerido").max(200),
  menuOrder: z.coerce.number().int().min(0).max(9999).default(0),
  type: z.string().min(1).max(20),
  idParent: z.number().int().nullable().default(null),
});

/**
 * App entity (SSO_V2). Two fields:
 * <ul>
 *   <li>{@code name} — unique, required, max 255. Backend also
 *       enforces this via Bean Validation; duplicate-name
 *       errors surface as a 409 {@code DUPLICATE} and the
 *       {@code Form} component renders them as a red toast.</li>
 *   <li>{@code description} — optional, max 500. Empty string
 *       coerces to {@code ""} so the input keeps a stable shape.</li>
 * </ul>
 * Bindings (roles/users/routes/microservices) are NOT in the
 * schema — they ride on dedicated endpoints, so each toggle
 * is its own HTTP round-trip with explicit error reporting.
 */
export const appFormSchema = z.object({
  name: z.string().min(1, "Requerido").max(255, "Máximo 255 caracteres"),
  description: z.string().max(500, "Máximo 500 caracteres").default(""),
  launchUrl: z.string().max(500, "Máximo 500 caracteres").default(""),
});

/**
 * Schema for the Queries Catalog admin form. The two
 * cross-field checks worth noting:
 * <ul>
 *   <li>{@code type} is optional, but admins sometimes paste
 *       a "SELECT" / "CHART" label here — keep it short and
 *       free-form; the backend will echo whatever is sent
 *       back to the consumer.</li>
 *   <li>{@code microserviceId} is null by default (query
 *       stays "global", canonical {@code query-service}
 *       serves it). Setting it requires picking a row out of
 *       the QUERY microservice dropdown the page renders;
 *       the schema accepts any positive integer, the form
 *       coerces empty string to {@code null}.</li>
 * </ul>
 *
 * <p>{@code query} (the SQL itself) is NOT validated for
 * syntax — Bean Validation 400 from the backend covers
 * malformed payloads, and trying to lint SQL here would just
 * shadow whatever the JDBC driver ends up complaining about.
 */
export const queryFormSchema = z.object({
  uuid: z
    .string()
    .min(2, "Mínimo 2 caracteres")
    .max(64)
    .regex(/^[a-zA-Z0-9_-]+$/, "Solo letras, números, _ y -"),
  query: z.string().min(1, "Requerido").max(10_000),
  type: z.string().max(64).default(""),
  publicEnd: z.boolean().default(false),
  captcha: z.boolean().default(false),
  detail: z.string().max(20_000).default(""),
  action: z.string().max(20_000).default(""),
  style: z.string().max(20_000).default(""),
  // Empty string from the <select> means "no binding"; coerce
  // to null so the backend's resolveQueryMicroservice(null)
  // path runs.
  microserviceId: z
    .union([z.string(), z.number(), z.null()])
    .transform((v) => {
      if (v === "" || v == null) return null;
      const n = typeof v === "string" ? Number(v) : v;
      return Number.isFinite(n) && n > 0 ? n : null;
    })
    .nullable()
    .default(null),
});

export type UserFormValues = z.infer<typeof userFormSchema>;
export type RoleFormValues = z.infer<typeof roleFormSchema>;
export type GroupFormValues = z.infer<typeof groupFormSchema>;
export type MicroserviceFormValues = z.infer<typeof microserviceFormSchema>;
export type EndpointFormValues = z.infer<typeof endpointFormSchema>;
export type RouteFormValues = z.infer<typeof routeFormSchema>;
export type AppFormValues = z.infer<typeof appFormSchema>;
export type QueryFormValues = z.infer<typeof queryFormSchema>;
export type WriteFormValues = z.infer<typeof writeFormSchema>;

/**
 * Schema for the Writes Catalog admin form.
 *
 * <p>The wire shape is JSON-as-string for {@code columns} and
 * {@code keyColumns} (the backend stores them in a TEXT
 * column). The form, however, holds them as {@code string[]}
 * — the natural shape for the {@code <ChipInput>} primitive.
 * The drawer's submit handler bridges the two
 * ({@code JSON.stringify} → wire,
 * {@code JSON.parse} ← response).
 *
 * <p>Field-by-field:
 * <ul>
 *   <li>{@code uuid} — required, max 64, same regex as queries:
 *       {@code [a-zA-Z0-9_-]+}. The uuid is the handle
 *       query-service consumes via
 *       {@code GET /write/byUuid?uuid=...}.</li>
 *   <li>{@code writeType} — enum INSERT|UPDATE. Select, not
 *       radio: only two options, the native select is
 *       less ceremony.</li>
 *   <li>{@code tableName} — required, max 200, must be
 *       qualified ({@code schema.table}). The regex refuses
 *       {@code users} / {@code public} alone — exactly the
 *       case Bean Validation catches on the backend.</li>
 *   <li>{@code columns} — chip array, min 1 (matches the
 *       backend's {@code @NotBlank}).</li>
 *   <li>{@code keyColumns} — chip array, optional, empty by
 *       default. Only meaningful for {@code writeType=UPDATE}
 *       but the schema doesn't enforce that; the user can
 *       freely leave it empty for INSERT.</li>
 *   <li>{@code microserviceId} — null by default (write is
 *       "global", any {@code query-service-<instance>} with
 *       the right datasource may serve it). The form exposes
 *       a {@code kind=QUERY} dropdown; selecting one enables
 *       the {@code TablePicker} panel so the operator doesn't
 *       have to type {@code schema.table} blind. Empty
 *       string from the {@code <select>} coerces to
 *       {@code null} (mirrors {@code queryFormSchema.microserviceId}).</li>
 * </ul>
 *
 * <p>{@code keyColumns} defaults to {@code []} so the form
 * shape stays stable when editing an INSERT row that has
 * no key columns in the DB. {@code microserviceId} defaults
 * to {@code null} for the same stability reason.
 */
export const writeFormSchema = z.object({
  uuid: z
    .string()
    .min(1, "Requerido")
    .max(64, "Máximo 64 caracteres")
    .regex(/^[a-zA-Z0-9_-]+$/, "Solo letras, números, guion y guion bajo"),
  writeType: z.enum(["INSERT", "UPDATE"], {
    errorMap: () => ({ message: "Tipo inválido" }),
  }),
  // Empty string from the <select> means "no binding";
  // coerce to null so the backend's
  // resolveWriteMicroservice(null) path runs (mirrors
  // queryFormSchema.microserviceId on the Queries Catalog
  // form — both feed into the same service-layer pattern).
  microserviceId: z
    .union([z.string(), z.number(), z.null()])
    .transform((v) => {
      if (v === "" || v == null) return null;
      const n = typeof v === "string" ? Number(v) : v;
      return Number.isFinite(n) && n > 0 ? n : null;
    })
    .nullable()
    .default(null),
  tableName: z
    .string()
    .min(1, "Requerido")
    .max(200, "Máximo 200 caracteres")
    .regex(
      /^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_]*$/,
      "Debe ser schema.table (ej: public.users)",
    ),
  columns: z
    .array(z.string().min(1, "Vacío"))
    .min(1, "Al menos una columna"),
  keyColumns: z.array(z.string()).default([]),
});

/**
 * Loose schema for the parameter bag sent to query-service's
 * {@code POST /query}. The service forwards each value via
 * {@code MapSqlParameterSource}, so the runtime SQL type
 * depends on the JDBC driver — the schema accepts the union
 * (string | number | boolean | null) that covers every type
 * `rs.getObject(i)` can return for a parameter binding.
 *
 * <p>No `superRefine` here — the v1 auto-parse generates one
 * input per `:placeholder`, so each field is validated when
 * the user types into it (the input is a free-form string,
 * which is what `MapSqlParameterSource` wants).
 */
export const queryParamSchema = z.record(
  z.string(),
  z.union([z.string(), z.number(), z.boolean(), z.null()]),
);
export type QueryParams = z.infer<typeof queryParamSchema>;
