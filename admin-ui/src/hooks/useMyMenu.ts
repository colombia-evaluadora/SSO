import { useQuery } from "@tanstack/react-query";
import { menuApi } from "@/api/endpoints";

/**
 * Query keys for the per-caller sidebar menu.
 *
 * <p>Namespaced at the top level ({@code ["myMenu"]}) so other
 * parts of the app can {@code invalidateQueries({queryKey:
 * ["myMenu"]})} if they rebind a route or a user's roles in
 * the same session. The Admin sidebar component consumes
 * this hook.
 */
export const menuKeys = {
  all: ["myMenu"] as const,
  list: () => [...menuKeys.all, "list"] as const,
};

/**
 * Reads {@code GET /sso-admin/myMenu}. Server returns the
 * already-filtered list (per-row authorization via
 * {@code RouteRepository.findVisibleForRoles}) — empty
 * array is a legitimate "no menu access" outcome, NOT an
 * error.
 *
 * <p>{@code staleTime: 5 min}: the menu only changes when
 * an admin rebinds a route or a user's role. Refetching on
 * every mount adds a round-trip for a list that's almost
 * always the same; a 5-min staleness window balances that
 * against needing to pick up a rebinding done in another
 * tab.
 *
 * <p>{@code retry: 0}: the underlying {@code apiClient}
 * already does one transparent 401 → /auth/refresh → retry
 * dance. Adding another retry layer would mask 4xx errors
 * that should bubble (e.g. 403).
 *
 * <p>The hook is intentionally read-only — mutations that
 * affect the menu (bind/unbind route, bind/unbind role)
 * live on the admin CRUD pages and are not coupled to
 * invalidation here (admins are typically not the same
 * session as the user whose menu would change).
 */
export function useMyMenu() {
  return useQuery({
    queryKey: menuKeys.list(),
    queryFn: () => menuApi.getMyMenu(),
    staleTime: 5 * 60 * 1000,
    retry: 0,
  });
}
