import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { groupsApi } from "@/api/endpoints";
import type { GroupRequest, GroupResponse, GroupRoleChecked } from "@/api/types";

export const groupKeys = {
  all: ["groups"] as const,
  list: () => [...groupKeys.all, "list"] as const,
  rolesChecked: (id: number) =>
    [...groupKeys.all, "rolesChecked", id] as const,
};

export function useGroups() {
  return useQuery({
    queryKey: groupKeys.list(),
    queryFn: () => groupsApi.list(),
  });
}

export function useCreateGroup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: GroupRequest) => groupsApi.save(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: groupKeys.list() });
    },
  });
}

export function useUpdateGroup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: GroupRequest) => groupsApi.update(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: groupKeys.list() });
    },
  });
}

export function useBindUserGroup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ userId, groupId }: { userId: number; groupId: number }) =>
      groupsApi.bindUser(userId, groupId),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: groupKeys.list() });
    },
  });
}

/* ====================== role bindings ====================== */

export function useGroupRolesChecked(id: number | null) {
  return useQuery({
    queryKey:
      id == null ? groupKeys.rolesChecked(0) : groupKeys.rolesChecked(id),
    queryFn: () => groupsApi.getRolesChecked(id!),
    enabled: id != null,
  });
}

export function useBindGroupRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      groupsApi.bindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: groupKeys.rolesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: groupKeys.list() });
    },
  });
}

export function useUnbindGroupRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      groupsApi.unbindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: groupKeys.rolesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: groupKeys.list() });
    },
  });
}

export type { GroupResponse, GroupRoleChecked };
