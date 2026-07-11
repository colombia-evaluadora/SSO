import { Navigate, Outlet, useLocation } from "react-router-dom";
import { useAuth } from "./useAuth";

/**
 * Route wrapper. While we're checking the silent refresh on mount
 * we show nothing (avoids a flash of the login page for already-
 * logged-in users). Once we know the state, redirect unauth'd
 * users to /admin/login (preserving the attempted path in `from`
 * so the login page can navigate back on success).
 */
export function RequireAuth() {
  const { status } = useAuth();
  const location = useLocation();

  if (status === "loading") {
    return (
      <div
        role="status"
        aria-label="Loading session"
        className="flex h-screen items-center justify-center text-slate-500"
      >
        Cargando…
      </div>
    );
  }
  if (status === "unauthenticated") {
    return <Navigate to="/admin/login" replace state={{ from: location.pathname }} />;
  }
  return <Outlet />;
}
