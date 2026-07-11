import { useState, type FormEvent } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { apiClient } from "@/api/client";

/**
 * Public restore-password page. The user clicks the link in
 * their restore-password email and lands here at
 * {@code /admin/restore-password?token=…}. We render a small
 * password form; on submit we POST {@code {token, password}}
 * to {@code /sso-admin/restorePassword}.
 *
 * <p>The password is sent in the JSON body, never in the URL —
 * the legacy GET-with-password-in-query leaked it via server
 * logs, proxy logs, browser history and the {@code Referer}
 * header (and made CSRF trivially weaponizable with
 * {@code <img src="…?token=…&password=PWN">}). The restore
 * {@code token} is a per-account single-use UUID that only the
 * email recipient knows, so it still functions as the
 * capability that gates the action.
 *
 * <p>The endpoint is {@code permitAll} in the backend, so we
 * call it with {@code skipAuth: true}. On success we show a
 * short "your password was updated" message and a link to
 * the login page.
 *
 * <p>Mirror of {@link ActivatePage} with copy and route tuned
 * for restore-password rather than activation.
 */
export function RestorePasswordPage() {
  const [params] = useSearchParams();
  const token = params.get("token") ?? "";

  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [state, setState] = useState<"form" | "ok" | "error">(
    token ? "form" : "error",
  );
  const [message, setMessage] = useState<string>(
    token ? "" : "Falta el token de restauración.",
  );

  // Local-only guard before we hit the backend: passwords
  // must match and be at least 6 chars (matches the @Size on
  // the backend DTO). The backend treats the two-field
  // equality as an out-of-band concern and only validates
  // length, which is the established pattern for activation
  // and restore flows.
  const mismatch = confirm.length > 0 && password !== confirm;
  const tooShort = password.length > 0 && password.length < 6;
  const canSubmit =
    token.length > 0 && password.length >= 6 && password === confirm && !submitting;

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!canSubmit) return;
    setSubmitting(true);
    try {
      await apiClient.post(
        "/sso-admin/restorePassword",
        { token, password },
        { skipAuth: true },
      );
      setState("ok");
      setMessage(
        "Tu contraseña ha sido actualizada. Inicia sesión para continuar.",
      );
    } catch (err) {
      setState("error");
      setMessage(
        err instanceof Error
          ? err.message
          : "No se pudo restaurar la contraseña.",
      );
    } finally {
      setSubmitting(false);
    }
  }

  if (state === "ok") {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
        <div
          role="alert"
          className="w-full max-w-md rounded-lg border border-emerald-200 bg-white p-6 shadow-sm"
        >
          <h1 className="mb-2 text-lg font-semibold text-slate-900">
            Restaurar contraseña
          </h1>
          <p className="text-sm text-slate-700">{message}</p>
          <Link
            to="/admin/login"
            className="mt-4 inline-block rounded bg-sky-600 px-3 py-2 text-sm font-medium text-white hover:bg-sky-700"
          >
            Ir a iniciar sesión
          </Link>
        </div>
      </main>
    );
  }

  if (state === "error" && !token) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
        <div
          role="alert"
          className="w-full max-w-md rounded-lg border border-red-200 bg-white p-6 shadow-sm"
        >
          <h1 className="mb-2 text-lg font-semibold text-slate-900">
            Restaurar contraseña
          </h1>
          <p className="text-sm text-slate-700">{message}</p>
        </div>
      </main>
    );
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
      <form
        onSubmit={onSubmit}
        aria-label="Restore password form"
        className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-sm"
      >
        <h1 className="mb-1 text-xl font-semibold text-slate-900">
          Restaurar contraseña
        </h1>
        <p className="mb-6 text-sm text-slate-500">
          Define la nueva contraseña para tu cuenta.
        </p>

        {state === "error" && message ? (
          <div
            role="alert"
            className="mb-4 rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
          >
            {message}
          </div>
        ) : null}

        <label className="mb-3 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">
            Nueva contraseña
          </span>
          <input
            type="password"
            autoComplete="new-password"
            required
            minLength={6}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full rounded border border-slate-300 px-3 py-2 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
          />
          {tooShort ? (
            <span className="mt-1 block text-xs text-red-600">
              Debe tener al menos 6 caracteres.
            </span>
          ) : null}
        </label>

        <label className="mb-4 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">
            Repetir contraseña
          </span>
          <input
            type="password"
            autoComplete="new-password"
            required
            minLength={6}
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            className="w-full rounded border border-slate-300 px-3 py-2 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
          />
          {mismatch ? (
            <span className="mt-1 block text-xs text-red-600">
              Las contraseñas no coinciden.
            </span>
          ) : null}
        </label>

        <button
          type="submit"
          disabled={!canSubmit}
          className="w-full rounded bg-sky-600 px-3 py-2 font-medium text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting ? "Restaurando…" : "Restaurar contraseña"}
        </button>
      </form>
    </main>
  );
}
