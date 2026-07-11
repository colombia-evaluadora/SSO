import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { queryAdminApi } from "@/api/endpoints";
import type { QueryAdminRequest, QueryAdminResponse, QueryRoleChecked } from "@/api/types";

/**
 * TanStack Query keys for the queries catalog CRUD surface
 * ({@code QueriesAdminPage}). Query execution is a fire-and-
 * forget mutation ({@link useExecuteQuery}) with no cached list
 * of its own, so nothing here needs to coordinate with it.
 */
export const queryAdminKeys = {
  all: ["queryAdmin"] as const,
  list: () => [...queryAdminKeys.all, "list"] as const,
  rolesChecked: (id: number) => [...queryAdminKeys.all, "rolesChecked", id] as const,
};

export function useAdminQueries() {
  return useQuery({
    queryKey: queryAdminKeys.list(),
    queryFn: () => queryAdminApi.list(),
  });
}

export function useQueryRolesChecked(id: number | null) {
  return useQuery({
    queryKey: queryAdminKeys.rolesChecked(id ?? 0),
    queryFn: () => queryAdminApi.getRolesChecked(id!),
    enabled: id != null,
  });
}

export function useCreateQuery() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: QueryAdminRequest) => queryAdminApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: queryAdminKeys.list() });
    },
  });
}

export function useUpdateQuery() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: QueryAdminRequest) => queryAdminApi.update(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: queryAdminKeys.list() });
    },
  });
}

export function useDeleteQuery() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => queryAdminApi.delete(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: queryAdminKeys.list() });
    },
  });
}

export function useBindQueryRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      queryAdminApi.bindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: queryAdminKeys.rolesChecked(vars.id),
      });
    },
  });
}

export function useUnbindQueryRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      queryAdminApi.unbindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: queryAdminKeys.rolesChecked(vars.id),
      });
    },
  });
}

export type { QueryAdminRequest, QueryAdminResponse, QueryRoleChecked };

/**
 * Manually invalidate the admin list after a role-binding or
 * delete change so the roles-count column refetches. The page
 * calls this after closing its role modal / confirming a delete.
 */
export function useInvalidateQueryAdminAndCatalog() {
  const qc = useQueryClient();
  return () => {
    void qc.invalidateQueries({ queryKey: queryAdminKeys.all });
  };
}
