import { useQuery } from "@tanstack/react-query";
import { apiClient } from "@/api/client";
import type { ColumnInfo } from "@/api/types";

/**
 * Cache key for the column catalog of one table on one
 * microservice instance. Keyed on (instanceName, schema, table)
 * so flipping the table or schema triggers a refetch instead of
 * inheriting the previous picker's result.
 */
export const tableColumnKeys = {
  all: ["table-columns"] as const,
  byTarget: (instanceName: string, schema: string, table: string) =>
    [...tableColumnKeys.all, instanceName, schema, table] as const,
};

export interface MicroserviceTableColumnsSource {
  /** The {@code QUERY_INSTANCE_NAME} for the gateway URL. */
  instanceName: string;
  /** Required by the {@code /columns} endpoint. */
  dialect: string;
  /** Required by {@code /columns}. Echo from
   *  {@code TableInfo.schema}; the admin form feeds back the
   *  schema it just autofilled from the TablePicker. */
  schema: string;
  /** Required by {@code /columns}. The qualified
   *  {@code schema + "." + name} the admin picked from the
   *  TablePicker — the components split it before passing
   *  the parts in. */
  table: string;
}

/**
 * Loads the list of base columns of one picked table on one
 * {@code query-service-<name>} instance. Used by the admin-ui
 * Writes Catalog "pick column(s)" panel.
 *
 * <p>URL surface: {@code GET /<serviceId>/columns?dialect=…&schema=…&table=…}
 * through the gateway's dynamic discovery locator. Pass
 * {@code base: ""} via {@link ApiClient.get} so the request
 * skips the {@code /api} prefix and hits the locator route
 * directly — same idiom {@code queriesApi.execute} and
 * {@code useMicroserviceTables} use.
 *
 * <p>{@code enabled} is false when any of the four required
 * pieces (instanceName, dialect, schema, table) is missing —
 * the picker doesn't fire until the admin has picked a table.
 * When the source changes the key changes too, so an admin
 * flipping between tables gets a fresh list instead of
 * inheriting the previous table's columns.
 *
 * <p>{@code staleTime} is 60s — the column catalog rarely
 * changes in a single editing session and the underlying
 * metadata call hits the DB; avoiding an extra round-trip
 * per form re-render is a noticeable win. The {@code retry}
 * stays off because {@code useQuery} noise on a partial
 * source re-render would mask the underlying 400 response.
 */
export function useMicroserviceTableColumns(
  source: MicroserviceTableColumnsSource | null,
) {
  return useQuery({
    queryKey: source
      ? tableColumnKeys.byTarget(
          source.instanceName,
          source.schema,
          source.table,
        )
      : tableColumnKeys.byTarget("__none__", "__none__", "__none__"),
    queryFn: async () => {
      if (!source) throw new Error("no column source");
      const params = new URLSearchParams({
        dialect: source.dialect,
        schema: source.schema,
        table: source.table,
      });
      return apiClient.get<ColumnInfo[]>(
        `/query-service-${source.instanceName}/columns?${params.toString()}`,
        { base: "" },
      );
    },
    enabled:
      source != null &&
      !!source.dialect &&
      !!source.schema &&
      !!source.table,
    staleTime: 60_000,
    retry: false,
  });
}
