import { useAuth } from "@/auth/useAuth";

/**
 * Top bar: app name, current user, logout. No menu yet — sidebar
 * goes in a later task. For now this is a placeholder so the
 * App shell renders.
 */
export function Topbar() {
  const { user, logout } = useAuth();
  return (
    <header className="border-b border-slate-200 bg-white">
      <div className="mx-auto flex max-w-7xl items-center justify-between px-6 py-3">
        <div className="flex items-center gap-3">
          <span className="rounded bg-sky-600 px-2 py-0.5 text-xs font-semibold text-white">
            SSO
          </span>
          <span className="font-semibold text-slate-900">sso-admin</span>
        </div>
        <div className="flex items-center gap-3 text-sm">
          {user ? (
            <>
              <span className="text-slate-600">{user.email}</span>
              <button
                type="button"
                onClick={() => void logout()}
                className="rounded border border-slate-300 px-3 py-1 text-slate-700 hover:bg-slate-100"
              >
                Salir
              </button>
            </>
          ) : null}
        </div>
      </div>
    </header>
  );
}
