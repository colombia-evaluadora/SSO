import { useQuery } from "@tanstack/react-query";
import { apiClient } from "@/api/client";
import type { TableInfo } from "@/api/types";

/**
 * Cache key for the table catalog of one microservice instance.
 * Keyed on the {@code instanceName} (resolved to the
 * {@code query-service-<name>} gateway path) — dialects for the
 * same instance share one query so flipping the dialect filter
 * doesn't refetch when the user already picked the same backing
 * store.
 */
export const tableKeys = {
  all: ["tables"] as const,
  byInstance: (instanceName: string) =>
    [...tableKeys.all, instanceName] as const,
};

export interface MicroserviceTableSource {
  /** The {@code QUERY_INSTANCE_NAME} for the gateway URL. */
  instanceName: string;
  /** Required by the {@code /tables} endpoint. */
  dialect: string;
  /** Optional {@code schema} filter (matches
   *  {@code DatabaseMetaData.getTables} LIKE semantics — the
   *  service also enforces an identifier charset). */
  schema?: string;
}

/**
 * Loads the list of base tables for a {@code query-service-<name>}
 * instance. Used by the admin-ui Writes Catalog "pick a table"
 * dropdown.
 *
 * <p>URL surface: {@code GET /<serviceId>/tables?dialect=…}
 * through the gateway's dynamic discovery locator. Pass
 * {@code base: ""} via {@link ApiClient.get} so the request
 * skips the {@code /api} prefix and hits the locator route
 * directly — same idiom {@code queriesApi.execute} uses.
 *
 * <p>{@code enabled} is false when no source was supplied (drawer
 * open but no microservice picked yet). When the source changes
 * the key changes too, so an admin flipping between instances
 * immediately triggers a refetch instead of inheriting the
 * previous instance's catalog.
 *
 * <p>{@code staleTime} is 60s — the catalog rarely changes in
 * a single editing session and the underlying metadata call
 * hits the DB; avoiding an extra round-trip per form open
 * is a noticeable win.
 */
export function useMicroserviceTables(source: MicroserviceTableSource | null) {
  return useQuery({
    queryKey: source
      ? tableKeys.byInstance(source.instanceName)
      : tableKeys.byInstance("__none__"),
    queryFn: async () => {
      if (!source) throw new Error("no microservice source");
      const params = new URLSearchParams({ dialect: source.dialect });
      if (source.schema) params.set("schema", source.schema);
      return apiClient.get<TableInfo[]>(
        `/query-service-${source.instanceName}/tables?${params.toString()}`,
        { base: "" },
      );
    },
    enabled: source != null && !!source.dialect,
    staleTime: 60_000,
    retry: false,
  });
}
