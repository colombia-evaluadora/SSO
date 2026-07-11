import { z } from "zod";

/**
 * Runtime-validated environment. Vite replaces the values at build
 * time; Zod catches missing or malformed values at startup so we
 * fail fast with a useful error rather than discovering the
 * problem in a downstream fetch.
 *
 * VITE_API_BASE is required. The path /api in dev and prod is the
 * gateway-relative prefix; the gateway's WebFlux router forwards
 * /api/** to the appropriate downstream (auth-center for /api/auth/**,
 * sso-admin for /api/sso-admin/**, etc.).
 *
 * VITE_APP_NAME is OPTIONAL. When set, it scopes the SPA's
 * sidebar to a single {@code App} on the backend: the SPA appends
 * {@code ?app=<name>} to {@code GET /sso-admin/myMenu} so the
 * backend filters routes to that app's bundle. When unset, the
 * SPA calls {@code /myMenu} without a filter and gets the full
 * union across every app the caller's roles grant (the
 * pre-scoping behavior). Either is a legitimate build — the
 * optional field keeps CI envs that haven't migrated from
 * crashing at startup.
 *
 * <p>{@code z.preprocess} normalizes an empty string to
 * {@code undefined} before the {@code min(1).optional()} check
 * runs. This matters because Docker's default build arg
 * (see {@code api-gateway/Dockerfile}'s {@code ARG
 * VITE_APP_NAME=""}) sets the var to {@code ""}, not "unset" —
 * Vite inlines whatever is in {@code process.env} verbatim, so
 * {@code import.meta.env.VITE_APP_NAME} is the literal empty
 * string, not {@code undefined}. Zod's {@code .optional()}
 * only tolerates a MISSING key, not a present-but-invalid one,
 * so without this preprocess step every build that doesn't
 * explicitly set {@code VITE_APP_NAME} would fail
 * {@code min(1)} and crash the whole SPA at startup with
 * "Invalid environment".
 */
const envSchema = z.object({
  VITE_API_BASE: z.string().min(1).startsWith("/"),
  VITE_APP_NAME: z.preprocess(
    (v) => (v === "" ? undefined : v),
    z.string().min(1).optional(),
  ),
});

const parsed = envSchema.safeParse(import.meta.env);
if (!parsed.success) {
  // The error message is intentionally compact — this is a developer
  // build error, not a runtime user error.
  throw new Error(
    `[admin-ui] Invalid environment: ${parsed.error.issues
      .map((i) => `${i.path.join(".")}: ${i.message}`)
      .join(", ")}`,
  );
}

export const env = parsed.data;
export type Env = z.infer<typeof envSchema>;
