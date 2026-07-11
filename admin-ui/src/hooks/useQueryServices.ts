/**
 * Ops hooks for the Query Services page. The list itself comes
 * from the regular {@link useMicroservices} hook (filtered by
 * kind=QUERY on the page, so CRUD invalidation refreshes it);
 * these are the per-container hooks that proxy to the provisioner
 * via sso-admin — status, logs, and restart.
 *
 * Polling cadence for {@link useQueryServiceStatus}: 5s while
 * a row is in a non-UP state, 0 (idle) when every row is UP.
 * The 5s window is short enough that an operator watching the
 * page sees container boot progress in near-real-time, long
 * enough that we don't hammer the provisioner with 1Hz polls
 * for 30 rows.
 */
import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { queryServicesApi } from "@/api/endpoints";
import type { ContainerStatusResponse } from "@/api/types";

export const queryServiceKeys = {
  all: ["query-services"] as const,
  status: (id: number) => [...queryServiceKeys.all, "status", id] as const,
  logs: (id: number, tail: number) =>
    [...queryServiceKeys.all, "logs", id, tail] as const,
};

/**
 * Per-row container status with smart polling:
 *   - 5s while state ≠ "running" (operator wants to see boot
 *     progress, restart progress, exited → restarting, etc.)
 *   - idle when state = "running" (UP is steady, no churn)
 *   - idle when the row is "absent" (container is gone; no
 *     point polling until something changes)
 */
export function useQueryServiceStatus(id: number | null) {
  return useQuery({
    queryKey: id == null ? ["query-services", "status", "disabled"] : queryServiceKeys.status(id),
    queryFn: () => queryServicesApi.status(id as number),
    enabled: id != null,
    refetchInterval: (query) => {
      const data = query.state.data as ContainerStatusResponse | undefined;
      if (!data) return 5000;
      return data.state === "running" || data.state === "absent" ? false : 5000;
    },
  });
}

/**
 * Logs are fetched on-demand. The page triggers this when the
 * operator opens the Logs modal; the modal has a "Refresh"
 * button that invalidates the query.
 */
export function useQueryServiceLogs(id: number | null, tail: number) {
  return useQuery({
    queryKey:
      id == null ? ["query-services", "logs", "disabled"] : queryServiceKeys.logs(id, tail),
    queryFn: () => queryServicesApi.logs(id as number, tail),
    enabled: id != null,
  });
}

export function useRestartQueryService() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => queryServicesApi.restart(id),
    onSuccess: (_void, id) => {
      // Force a status poll — the new state will be "restarting"
      // then "running".
      void qc.invalidateQueries({ queryKey: queryServiceKeys.status(id) });
    },
  });
}
