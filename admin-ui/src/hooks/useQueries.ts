import { useMutation } from "@tanstack/react-query";
import { queriesApi } from "@/api/endpoints";
import type {
  QueryExecutionRequest,
  QueryExecutionResponse,
  QueryParamValue,
} from "@/api/types";

/**
 * Executes a query against the chosen query-service instance.
 * Returns TanStack Query's standard `useMutation` shape — call
 * `.mutateAsync({ instanceName, body })` from the execute
 * button in {@code QueriesAdminPage}.
 *
 * <p>Nothing is invalidated on success because
 * `POST /query` is side-effect-free on the catalog side.
 */
export function useExecuteQuery() {
  return useMutation<
    QueryExecutionResponse,
    Error,
    { instanceName: string | null; body: QueryExecutionRequest }
  >({
    mutationFn: ({ instanceName, body }) =>
      queriesApi.execute(instanceName, body),
  });
}

export type {
  QueryExecutionRequest,
  QueryExecutionResponse,
  QueryParamValue,
};
