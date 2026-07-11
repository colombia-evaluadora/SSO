import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { endpointsApi } from "@/api/endpoints";
import type {
  EndpointMicroserviceChecked,
  EndpointRequest,
  EndpointResponse,
  EndpointRoleChecked,
} from "@/api/types";

export const endpointKeys = {
  all: ["endpoints"] as const,
  list: () => [...endpointKeys.all, "list"] as const,
  rolesChecked: (id: number) => [...endpointKeys.all, "rolesChecked", id] as const,
  microservicesChecked: (id: number) =>
    [...endpointKeys.all, "microservicesChecked", id] as const,
};

export function useEndpoints() {
  return useQuery({
    queryKey: endpointKeys.list(),
    queryFn: () => endpointsApi.list(),
  });
}

export function useEndpointRolesChecked(id: number | null) {
  return useQuery({
    queryKey: endpointKeys.rolesChecked(id ?? 0),
    queryFn: () => endpointsApi.getRolesChecked(id!),
    enabled: id != null,
  });
}

export function useEndpointMicroservicesChecked(id: number | null) {
  return useQuery({
    queryKey: endpointKeys.microservicesChecked(id ?? 0),
    queryFn: () => endpointsApi.getMicroservicesChecked(id!),
    enabled: id != null,
  });
}

export function useCreateEndpoint() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: EndpointRequest) => endpointsApi.create(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: endpointKeys.list() });
    },
  });
}

export function useUpdateEndpoint() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: EndpointRequest) => endpointsApi.update(body),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: endpointKeys.list() });
    },
  });
}

export function useDeleteEndpoint() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => endpointsApi.delete(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: endpointKeys.list() });
    },
  });
}

export function useBindEndpointRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      endpointsApi.bindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: endpointKeys.rolesChecked(vars.id),
      });
    },
  });
}

export function useUnbindEndpointRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, roleId }: { id: number; roleId: number }) =>
      endpointsApi.unbindRole(id, roleId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: endpointKeys.rolesChecked(vars.id),
      });
    },
  });
}

export function useBindEndpointMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, microserviceId }: { id: number; microserviceId: number }) =>
      endpointsApi.bindMicroservice(id, microserviceId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: endpointKeys.microservicesChecked(vars.id),
      });
    },
  });
}

export function useUnbindEndpointMicroservice() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, microserviceId }: { id: number; microserviceId: number }) =>
      endpointsApi.unbindMicroservice(id, microserviceId),
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({
        queryKey: endpointKeys.microservicesChecked(vars.id),
      });
    },
  });
}

export type { EndpointResponse, EndpointRoleChecked, EndpointMicroserviceChecked };
