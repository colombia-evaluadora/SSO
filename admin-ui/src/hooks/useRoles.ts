import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { rolesApi } from "@/api/endpoints";
import type { RoleRequest, RoleResponse, UserRoleChecked } from "@/api/types";

export const roleKeys = {
  all: ["roles"] as const,
  list: () => [...roleKeys.all, "list"] as const,
  usersChecked: (roleId: number) =>
    [...roleKeys.all, "usersChecked", roleId] as const,
};

export function useRoles() {
  return useQuery({
    queryKey: roleKeys.list(),
    queryFn: () => rolesApi.list(),
  });
}

export function useRoleUsersChecked(roleId: number | null) {
  return useQuery({
    queryKey: roleKeys.usersChecked(roleId ?? 0),
    queryFn: () => rolesApi.getUsersChecked(roleId!),
    enabled: roleId != null,
  });
}

export function useCreateRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: RoleRequest) => rolesApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: roleKeys.list() });
    },
  });
}

export function useUpdateRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: RoleRequest) => rolesApi.update(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: roleKeys.list() });
    },
  });
}

export type { RoleResponse, UserRoleChecked };
