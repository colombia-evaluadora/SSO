import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { authApi } from "@/api/endpoints";
import type { AppSummary } from "@/api/types";
import { env } from "@/env";

interface LocationState {
  apps?: AppSummary[];
}

/**
 * Post-login "which app do you want to open" screen. Only reached
 * when the caller's roles have {@code role_app} access to 2+ apps
 * — {@link ../auth/LoginPage} skips straight to {@code /admin}
 * when there's just 1 (today's default, and still the common
 * case). Mounted at {@code /admin/select-app}, inside the
 * {@code RequireAuth}-gated tree but outside the sidebar
 * {@code <App>} layout — this is a waypoint, not a page within
 * SSO-ADMIN's own navigation (not to be confused with
 * {@code /admin/apps}, the Apps CRUD admin screen).
 *
 * <p>Prefers the app list {@code LoginPage} already fetched (passed
 * via router {@code state}) to avoid a duplicate round-trip; falls
 * back to fetching it itself so a direct nav or refresh on this
 * URL still works.
 */
export function AppLauncherPage() {
  const location = useLocation();
  const navigate = useNavigate();
  const stateApps = (location.state as LocationState | null)?.apps;

  const [apps, setApps] = useState<AppSummary[] | null>(stateApps ?? null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (stateApps) return;
    let cancelled = false;
    authApi
      .myApps()
      .then((result) => {
        if (!cancelled) setApps(result);
      })
      .catch(() => {
        if (!cancelled) setError("No se pudieron cargar tus apps.");
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function openApp(app: AppSummary) {
    if (app.name === env.VITE_APP_NAME) {
      navigate("/admin/users", { replace: true });
      return;
    }
    if (app.launchUrl) {
      window.location.href = app.launchUrl;
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
      <div className="w-full max-w-2xl">
        <h1 className="mb-1 text-xl font-semibold text-slate-900">
          Elige una app
        </h1>
        <p className="mb-6 text-sm text-slate-500">
          Tu usuario tiene acceso a más de una aplicación.
        </p>

        {error ? (
          <div
            role="alert"
            className="mb-4 rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
          >
            {error}
          </div>
        ) : null}

        {apps === null && !error ? (
          <p className="text-sm text-slate-500">Cargando…</p>
        ) : null}

        {apps && apps.length > 0 ? (
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            {apps.map((app) => {
              const disabled =
                app.name !== env.VITE_APP_NAME && !app.launchUrl;
              return (
                <button
                  key={app.id}
                  type="button"
                  disabled={disabled}
                  onClick={() => openApp(app)}
                  className="rounded-lg border border-slate-200 bg-white p-4 text-left shadow-sm transition hover:border-sky-400 hover:shadow disabled:cursor-not-allowed disabled:opacity-60 disabled:hover:border-slate-200 disabled:hover:shadow-sm"
                >
                  <h2 className="font-medium text-slate-900">{app.name}</h2>
                  {app.description ? (
                    <p className="mt-1 text-sm text-slate-500">
                      {app.description}
                    </p>
                  ) : null}
                  {disabled ? (
                    <p className="mt-2 text-xs text-red-600">
                      URL no configurada
                    </p>
                  ) : null}
                </button>
              );
            })}
          </div>
        ) : null}

        {apps && apps.length === 0 ? (
          <p className="text-sm text-slate-500">
            No tienes apps asignadas. Contacta a un administrador.
          </p>
        ) : null}
      </div>
    </main>
  );
}
