import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { authApi } from "@/api/endpoints";

/**
 * Public "request a password reset" page — the entry point the
 * login screen's "¿Olvidaste tu contraseña?" link points at. The
 * user types their email; we POST it to {@code /forgotPassword}
 * and always show the same generic confirmation, regardless of
 * whether the email is actually registered (the backend, per
 * {@code UserAdminService.forgotPassword}, never discloses which
 * addresses exist — mirroring that here means the confirmation
 * text can't be used to enumerate accounts either).
 *
 * <p>This is step 1 of 2. Step 2 is {@link RestorePasswordPage},
 * which the emailed link points at ({@code /admin/restore-password
 * ?token=…}) and where the user actually sets a new password.
 */
export function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!email) return;
    setSubmitting(true);
    try {
      await authApi.forgotPassword(email);
    } catch {
      // Deliberately ignored — same generic confirmation either
      // way, so a network blip doesn't leak anything either and
      // the user can just retry from the same screen.
    } finally {
      setSubmitting(false);
      setSubmitted(true);
    }
  }

  if (submitted) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
        <div
          role="alert"
          className="w-full max-w-md rounded-lg border border-emerald-200 bg-white p-6 shadow-sm"
        >
          <h1 className="mb-2 text-lg font-semibold text-slate-900">
            Restaurar contraseña
          </h1>
          <p className="text-sm text-slate-700">
            Si <strong>{email}</strong> está registrado, te enviamos un
            correo con un enlace para restaurar tu contraseña.
          </p>
          <Link
            to="/admin/login"
            className="mt-4 inline-block rounded bg-sky-600 px-3 py-2 text-sm font-medium text-white hover:bg-sky-700"
          >
            Volver a iniciar sesión
          </Link>
        </div>
      </main>
    );
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-100 px-4">
      <form
        onSubmit={onSubmit}
        aria-label="Forgot password form"
        className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-sm"
      >
        <h1 className="mb-1 text-xl font-semibold text-slate-900">
          Restaurar contraseña
        </h1>
        <p className="mb-6 text-sm text-slate-500">
          Ingresa tu email y te enviaremos un enlace para restaurar tu
          contraseña.
        </p>

        <label className="mb-4 block text-sm">
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

        <button
          type="submit"
          disabled={submitting || !email}
          className="w-full rounded bg-sky-600 px-3 py-2 font-medium text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting ? "Enviando…" : "Enviar enlace"}
        </button>

        <Link
          to="/admin/login"
          className="mt-4 block text-center text-sm text-sky-600 hover:underline"
        >
          Volver a iniciar sesión
        </Link>
      </form>
    </main>
  );
}
