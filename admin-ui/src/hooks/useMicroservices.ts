import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { microservicesApi } from "@/api/endpoints";
import type { MicroserviceRequest, MicroserviceResponse } from "@/api/types";

export const microserviceKeys = {
  all: ["microservices"] as const,
  list: () => [...microserviceKeys.all, "list"] as const,
};

export function useMicroservices() {
  // Polling: only re-fetch every 5s while there's at least
  // one QUERY row, because the only field that changes
  // out-of-band is the container's runtime state (UP /
  // PROVISIONING / DOWN). For REST-only lists the query
  // sits idle — no waste.
  //
  // `refetchIntervalInBackground: false` suspends the polling
  // when the tab is hidden. The admin opens the page, checks
  // container state, then switches tabs — the polling should
  // not consume backend cycles while nobody is looking. The
  // default `refetchOnWindowFocus: true` re-fetches the
  // moment the admin comes back to the tab, so freshness
  // is preserved on focus.
  return useQuery({
    queryKey: microserviceKeys.list(),
    queryFn: () => microservicesApi.list(),
    refetchInterval: (query) => {
      const rows = query.state.data;
      if (!rows) return false;
      return rows.some((m) => m.kind === "QUERY") ? 5000 : false;
    },
    refetchIntervalInBackground: false,
  });
}

export function useCreateMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: MicroserviceRequest) => microservicesApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: microserviceKeys.list() });
    },
  });
}

export function useUpdateMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: MicroserviceRequest) => microservicesApi.update(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: microserviceKeys.list() });
    },
  });
}

export function useDeleteMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => microservicesApi.delete(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: microserviceKeys.list() });
    },
  });
}

export type { MicroserviceResponse };
