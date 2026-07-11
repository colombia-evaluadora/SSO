import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { writesApi } from "@/api/endpoints";
import type {
  WriteDefinitionRequest,
  WriteDefinitionResponse,
  WriteRoleChecked,
} from "@/api/types";

/**
 * TanStack Query keys for the WriteDefinition admin CRUD
 * surface. Namespaced under {@code ["writes"]} so
 * {@code invalidateQueries({queryKey: writeKeys.all})} after
 * a CRUD mutation refreshes the list page (matches the
 * pattern used by {@link useApps}).
 *
 * <p>Per-row role listings are keyed by both family and
 * write id; a bind/unbind invalidates BOTH the specific
 * checked key AND {@code writeKeys.list()} so the role count
 * column in the table refreshes on the next render.
 */
export const writeKeys = {
  all: ["writes"] as const,
  list: () => [...writeKeys.all, "list"] as const,
  byId: (id: number) => [...writeKeys.all, "byId", id] as const,
  rolesChecked: (id: number) => [...writeKeys.all, "rolesChecked", id] as const,
};

/* ====================== CRUD ====================== */

export function useWrites() {
  return useQuery({
    queryKey: writeKeys.list(),
    queryFn: () => writesApi.list(),
  });
}

export function useWrite(id: number | null) {
  return useQuery({
    queryKey: id == null ? writeKeys.byId(0) : writeKeys.byId(id),
    queryFn: () => writesApi.getById(id!),
    enabled: id != null,
  });
}

export function useCreateWrite() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: WriteDefinitionRequest) => writesApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: writeKeys.all });
    },
  });
}

export function useUpdateWrite() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: WriteDefinitionRequest) => writesApi.update(body),
    onSuccess: (_data, vars) => {
      void qc.invalidateQueries({ queryKey: writeKeys.all });
      if (vars.id != null) {
        void qc.invalidateQueries({ queryKey: writeKeys.byId(vars.id) });
      }
    },
  });
}

export function useDeleteWrite() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => writesApi.delete(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: writeKeys.all });
    },
  });
}

/* ====================== role bindings ====================== */

export function useWriteRolesChecked(id: number | null) {
  return useQuery({
    queryKey: id == null ? writeKeys.rolesChecked(0) : writeKeys.rolesChecked(id),
    queryFn: () => writesApi.getRolesChecked(id!),
    enabled: id != null,
  });
}

export function useBindWriteRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      writesApi.bindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: writeKeys.rolesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: writeKeys.list() });
    },
  });
}

export function useUnbindWriteRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      writesApi.unbindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: writeKeys.rolesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: writeKeys.list() });
    },
  });
}

/* ====================== re-exports ====================== */

export type {
  WriteDefinitionRequest,
  WriteDefinitionResponse,
  WriteRoleChecked,
};
