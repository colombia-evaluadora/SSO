import { useContext } from "react";
import { AuthContext, type AuthContextValue } from "./AuthProvider";

export type { AuthContextValue };

/**
 * Typed accessor for the auth context. Throws if used outside an
 * {@link AuthProvider} so the error is loud at dev time rather
 * than silent (a `useAuth()` returning `null` and downstream code
 * doing `if (auth.user)` would have a bug-magnet null check).
 */
export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) {
    throw new Error("useAuth must be used inside <AuthProvider>");
  }
  return ctx;
}
