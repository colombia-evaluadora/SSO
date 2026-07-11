import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { routesApi } from "@/api/endpoints";
import type {
  RouteRequest,
  RouteResponse,
  RouteRoleChecked,
} from "@/api/types";

export const routeKeys = {
  all: ["routes"] as const,
  list: () => [...routeKeys.all, "list"] as const,
  listByParent: (parent: number | null) =>
    [...routeKeys.all, "listByParent", parent ?? "root"] as const,
  rolesChecked: (id: number) => [...routeKeys.all, "rolesChecked", id] as const,
};

export function useRoutes() {
  return useQuery({
    queryKey: routeKeys.list(),
    queryFn: () => routesApi.list(),
  });
}

export function useRoutesByParent(parent: number | null) {
  return useQuery({
    queryKey: routeKeys.listByParent(parent),
    queryFn: () => routesApi.listByParent(parent),
  });
}

export function useRouteRolesChecked(id: number | null) {
  return useQuery({
    queryKey: routeKeys.rolesChecked(id ?? 0),
    queryFn: () => routesApi.getRolesChecked(id!),
    enabled: id != null,
  });
}

export function useCreateRoute() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: RouteRequest) => routesApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: routeKeys.all });
    },
  });
}

export function useUpdateRoute() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: RouteRequest) => routesApi.update(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: routeKeys.all });
    },
  });
}

export function useDeleteRoute() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => routesApi.delete(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: routeKeys.all });
    },
  });
}

export function useBindRouteRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      routesApi.bindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: routeKeys.rolesChecked(vars.id) });
    },
  });
}

export function useUnbindRouteRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      routesApi.unbindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: routeKeys.rolesChecked(vars.id) });
    },
  });
}

export type { RouteResponse, RouteRoleChecked };
