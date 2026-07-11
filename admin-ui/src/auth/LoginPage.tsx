import { useState, type FormEvent } from "react";
import { Link, Navigate, useLocation, useNavigate } from "react-router-dom";
import { authApi } from "@/api/endpoints";
import { useAuth } from "./useAuth";

interface LocationState {
  from?: string;
}

/**
 * Login form. POSTs credentials to /api/auth/login; the backend
 * returns the access token in the body and sets the refresh cookie
 * in the response headers.
 *
 * <p>On success, where we navigate depends on why the user landed
 * here:
 * <ul>
 *   <li>they were bounced here from a specific deep link (e.g. a
 *       bookmark to {@code /admin/roles} while unauthenticated,
 *       preserved by {@code RequireAuth} as {@code location.state.from})
 *       — go straight there, unchanged. A deep link is a clear
 *       enough signal of intent that it should never be
 *       interrupted by the app picker below.</li>
 *   <li>otherwise (a plain visit to {@code /admin/login}, OR the
 *       generic unauthenticated-entry bounce to bare {@code /admin}
 *       — {@code RequireAuth} sets {@code state.from} to whatever
 *       path it intercepted, and for a first-time visit that's
 *       always {@code /admin} itself, not a real deep link; treated
 *       the same as no {@code from} at all) — check
 *       {@code /auth/myApps}: 2+ apps shows {@link AppLauncherPage}
 *       so the user picks where to go; 0 or 1 (today's default)
 *       skips straight to {@code /admin} as before. A failed
 *       {@code myApps} call is best-effort — it falls back to
 *       {@code /admin} rather than blocking an otherwise-successful
 *       login.</li>
 * </ul>
 *
 * <p>The login identifier is the user's email — the legacy
 * {@code username} column is gone since the V12 migration. The
 * field still has {@code autoComplete="email"} so password
 * managers fill it correctly.
 */
export function LoginPage() {
  const { status, login, error, clearError } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const rawFrom = (location.state as LocationState | null)?.from;
  // "/admin" isn't a real deep link — it's what RequireAuth records
  // for the generic entry bounce (visiting "/", bare "/admin", or
  // anything that redirects there before auth is known). Only a
  // MORE SPECIFIC path counts as an explicit destination worth
  // skipping the app picker for.
  const explicitFrom = rawFrom && rawFrom !== "/admin" ? rawFrom : undefined;
  const from = rawFrom ?? "/admin";

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);
  // login() dispatches LOGIN_SUCCESS (status -> "authenticated")
  // synchronously, well before onSubmit's own post-login navigate()
  // call below runs — without this flag the guard right below would
  // win that race and bounce straight to `from`, cutting off the
  // myApps() check entirely. Suppressed for the duration of our own
  // submit-triggered login; the "already authenticated on mount"
  // case (e.g. navigating back to /admin/login with a live session)
  // is unaffected since this starts false and onSubmit never ran.
  const [resolvingDestination, setResolvingDestination] = useState(false);

  if (status === "authenticated" && !resolvingDestination) {
    return <Navigate to={from} replace />;
  }

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setResolvingDestination(true);
    try {
      const ok = await login(email, password);
      if (!ok) {
        setResolvingDestination(false);
        return;
      }
      if (explicitFrom) {
        navigate(from, { replace: true });
        return;
      }
      try {
        const apps = await authApi.myApps();
        if (apps.length > 1) {
          navigate("/admin/select-app", { replace: true, state: { apps } });
        } else {
          navigate(from, { replace: true });
        }
      } catch {
        // Best-effort — never block a successful login on this.
        navigate(from, { replace: true });
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
      <form
        onSubmit={onSubmit}
        className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-sm"
        aria-label="Login form"
      >
        <h1 className="mb-1 text-xl font-semibold text-slate-900">sso-admin</h1>
        <p className="mb-6 text-sm text-slate-500">Inicia sesión para continuar.</p>

        {error ? (
          <div
            role="alert"
            className="mb-4 rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
            onClick={clearError}
          >
            {error}
          </div>
        ) : null}

        <label className="mb-3 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">Email</span>
          <input
            type="email"
            inputMode="email"
            autoComplete="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="w-full rounded border border-slate-300 px-3 py-2 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
          />
        </label>

        <label className="mb-4 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">Contraseña</span>
          <input
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full rounded border border-slate-300 px-3 py-2 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
          />
        </label>

        <button
          type="submit"
          disabled={submitting}
          className="w-full rounded bg-sky-600 px-3 py-2 font-medium text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting ? "Entrando…" : "Entrar"}
        </button>

        <Link
          to="/admin/forgot-password"
          className="mt-4 block text-center text-sm text-sky-600 hover:underline"
        >
          ¿Olvidaste tu contraseña?
        </Link>
      </form>
    </main>
  );
}
