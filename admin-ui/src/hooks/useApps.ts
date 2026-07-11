import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { appsApi } from "@/api/endpoints";
import type {
  AppRequest,
  AppResponse,
  AppRoleChecked,
  AppUserChecked,
  AppRouteChecked,
  AppMicroserviceChecked,
} from "@/api/types";

/**
 * TanStack Query keys for the App entity. We namespace the
 * four binding families under the same {@code all} prefix so a
 * single {@code invalidateQueries({queryKey: appKeys.all})}
 * after a CRUD mutation refreshes the list page.
 *
 * <p>Per-row checked listings are keyed by both family and
 * app id; a bind/unbind invalidates BOTH the specific checked
 * key AND {@code appKeys.list()} so the badge counts in the
 * table refresh on the next mount.
 */
export const appKeys = {
  all: ["apps"] as const,
  list: () => [...appKeys.all, "list"] as const,
  byId: (id: number) => [...appKeys.all, "byId", id] as const,
  rolesChecked: (id: number) =>
    [...appKeys.all, "rolesChecked", id] as const,
  usersChecked: (id: number) =>
    [...appKeys.all, "usersChecked", id] as const,
  routesChecked: (id: number) =>
    [...appKeys.all, "routesChecked", id] as const,
  microservicesChecked: (id: number) =>
    [...appKeys.all, "microservicesChecked", id] as const,
};

/* ====================== CRUD ====================== */

export function useApps() {
  return useQuery({
    queryKey: appKeys.list(),
    queryFn: () => appsApi.list(),
  });
}

export function useApp(id: number | null) {
  return useQuery({
    queryKey: id == null ? appKeys.byId(0) : appKeys.byId(id),
    queryFn: () => appsApi.getById(id!),
    enabled: id != null,
  });
}

export function useCreateApp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: AppRequest) => appsApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: appKeys.all });
    },
  });
}

export function useUpdateApp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: AppRequest) => appsApi.update(body),
    onSuccess: (_data, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.all });
      if (vars.id != null) {
        void qc.invalidateQueries({ queryKey: appKeys.byId(vars.id) });
      }
    },
  });
}

export function useDeleteApp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => appsApi.delete(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: appKeys.all });
    },
  });
}

/* ====================== role bindings ====================== */

export function useAppRolesChecked(id: number | null) {
  return useQuery({
    queryKey: id == null ? appKeys.rolesChecked(0) : appKeys.rolesChecked(id),
    queryFn: () => appsApi.getRolesChecked(id!),
    enabled: id != null,
  });
}

export function useBindAppRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      appsApi.bindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.rolesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

export function useUnbindAppRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      appsApi.unbindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.rolesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

/* ====================== user bindings ====================== */

export function useAppUsersChecked(id: number | null) {
  return useQuery({
    queryKey: id == null ? appKeys.usersChecked(0) : appKeys.usersChecked(id),
    queryFn: () => appsApi.getUsersChecked(id!),
    enabled: id != null,
  });
}

export function useBindAppUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, userId }: { id: number; userId: number }) =>
      appsApi.bindUser(id, userId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.usersChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

export function useUnbindAppUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, userId }: { id: number; userId: number }) =>
      appsApi.unbindUser(id, userId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.usersChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

/* ====================== route bindings ====================== */

export function useAppRoutesChecked(id: number | null) {
  return useQuery({
    queryKey:
      id == null ? appKeys.routesChecked(0) : appKeys.routesChecked(id),
    queryFn: () => appsApi.getRoutesChecked(id!),
    enabled: id != null,
  });
}

export function useBindAppRoute() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, routeId }: { id: number; routeId: number }) =>
      appsApi.bindRoute(id, routeId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.routesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

export function useUnbindAppRoute() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, routeId }: { id: number; routeId: number }) =>
      appsApi.unbindRoute(id, routeId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: appKeys.routesChecked(vars.id) });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

/* ====================== microservice bindings ====================== */

export function useAppMicroservicesChecked(id: number | null) {
  return useQuery({
    queryKey:
      id == null
        ? appKeys.microservicesChecked(0)
        : appKeys.microservicesChecked(id),
    queryFn: () => appsApi.getMicroservicesChecked(id!),
    enabled: id != null,
  });
}

export function useBindAppMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({
      id,
      microserviceId,
    }: {
      id: number;
      microserviceId: number;
    }) => appsApi.bindMicroservice(id, microserviceId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: appKeys.microservicesChecked(vars.id),
      });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

export function useUnbindAppMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({
      id,
      microserviceId,
    }: {
      id: number;
      microserviceId: number;
    }) => appsApi.unbindMicroservice(id, microserviceId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: appKeys.microservicesChecked(vars.id),
      });
      void qc.invalidateQueries({ queryKey: appKeys.list() });
    },
  });
}

/* ====================== re-exports for convenience ====================== */

export type {
  AppResponse,
  AppRoleChecked,
  AppUserChecked,
  AppRouteChecked,
  AppMicroserviceChecked,
};