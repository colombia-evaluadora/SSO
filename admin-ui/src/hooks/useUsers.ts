import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { usersApi } from "@/api/endpoints";
import type {
  BindUserRoleRequest,
  CreateAccountRequest,
  UpdateAccountRequest,
  UserResponse,
  UserRoleChecked,
} from "@/api/types";

/**
 * Centralised query keys. Keeping them in one place avoids the
 * "stale query key string" drift that bites you when invalidating
 * from a mutation in a different file.
 */
export const userKeys = {
  all: ["users"] as const,
  list: () => [...userKeys.all, "list"] as const,
  rolesChecked: (userId: number) =>
    [...userKeys.all, "rolesChecked", userId] as const,
};

export function useUsers() {
  return useQuery({
    queryKey: userKeys.list(),
    queryFn: () => usersApi.list(),
  });
}

export function useUserRolesChecked(userId: number | null) {
  return useQuery({
    queryKey: userKeys.rolesChecked(userId ?? 0),
    queryFn: () => usersApi.getRolesChecked(userId!),
    enabled: userId != null,
  });
}

export function useCreateUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: CreateAccountRequest) => usersApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: userKeys.list() });
    },
  });
}

export function useUpdateUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: UpdateAccountRequest) => usersApi.update(body),
    onSuccess: (_data, vars) => {
      void qc.invalidateQueries({ queryKey: userKeys.list() });
      void qc.invalidateQueries({ queryKey: userKeys.rolesChecked(vars.id) });
    },
  });
}

export function useResendActivation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (userId: number) => usersApi.resendActivation(userId),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: userKeys.list() });
    },
  });
}

export function useDeactivateUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ userId, reason }: { userId: number; reason?: string }) =>
      usersApi.deactivate(userId, reason),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: userKeys.list() });
    },
  });
}

export function useReactivateUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (userId: number) => usersApi.reactivate(userId),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: userKeys.list() });
    },
  });
}

export function useBindUserRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: BindUserRoleRequest) => usersApi.bindRole(body),
    onSuccess: (_data, vars) => {
      void qc.invalidateQueries({ queryKey: userKeys.rolesChecked(vars.userId) });
    },
  });
}

export function useUnbindUserRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ userId, roleId }: { userId: number; roleId: number }) =>
      usersApi.unbindRole(userId, roleId),
    onSuccess: (_data, vars) => {
      void qc.invalidateQueries({ queryKey: userKeys.rolesChecked(vars.userId) });
    },
  });
}

export type { UserResponse, UserRoleChecked };
